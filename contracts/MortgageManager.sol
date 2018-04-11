pragma solidity ^0.4.19;

import "./interfaces/Token.sol";
import "./interfaces/Cosigner.sol";
import "./interfaces/Engine.sol";
import "./interfaces/ERC721.sol";
import "./utils/ERCLockable.sol";
import "./utils/BytesUtils.sol";
import "./interfaces/Oracle.sol";

contract LandMarket {
    struct Auction {
        // Auction ID
        bytes32 id;
        // Owner of the NFT
        address seller;
        // Price (in wei) for the published item
        uint256 price;
        // Time when this sale ends
        uint256 expiresAt;
    }

    mapping (uint256 => Auction) public auctionByAssetId;
    function executeOrder(uint256 assetId, uint256 price) public;
}

contract KyberNetwork {
    function trade(
        address src,
        uint srcAmount,
        address dest,
        address destAddress,
        uint maxDestAmount,
        uint minConversionRate,
        address walletId
    ) public payable returns(uint);

    function getExpectedRate(address src, address dest, uint srcQty)
        public view
        returns (uint expectedRate, uint slippageRate);
}

contract Land is ERC721 {
    function updateLandData(int x, int y, string data) public;
    function decodeTokenId(uint value) view public returns (int, int);
}

contract MortgageManager is Cosigner, ERC721, ERCLockable, BytesUtils {
    uint256 constant internal PRECISION = (10**18);
    uint256 constant internal RCN_DECIMALS = 18;

    bytes32 public constant MANA_CURRENCY = 0x4d414e4100000000000000000000000000000000000000000000000000000000;
    uint256 public constant REQUIRED_ALLOWANCE = 1000000000 * 10**18;

    function name() public view returns (string _name) {
        _name = "Descentraland RCN Mortgage - Acacia";
    }

    function symbol() public view returns (string _symbol) {
        _symbol = "LAND-RCN-Mortgage";
    }

    event RequestedMortgage(uint256 _id, Type _type, address _borrower, address _engine, uint256 _loanId, uint256 _landId, uint256 _deposit);
    event StartedMortgage(uint256 _id);
    event CanceledMortgage(uint256 _id);
    event PaidMortgage(uint256 _id);
    event DefaultedMortgage(uint256 _id);

    Token public rcn = Token(0);
    Token public mana = Token(0);
    Land public land = Land(0);
    LandMarket public landMarket = LandMarket(0);
    KyberNetwork public kyberNetwork = KyberNetwork(0);

    function MortgageManager(Token _rcn, Token _mana, Land _land, LandMarket _landMarket, KyberNetwork _kyberNetwork) public {
        setTokenType(mana, ERCLockable.TokenType.ERC20);
        setTokenType(rcn, ERCLockable.TokenType.ERC20);
        setTokenType(land, ERCLockable.TokenType.ERC721);
        rcn = _rcn;
        mana = _mana;
        land = _land;
        landMarket = _landMarket;
        kyberNetwork = _kyberNetwork;
    }

    enum Status { Pending, Ongoing, Canceled, Paid, Defaulted }
    enum Type { Buy, Loan }

    struct Mortgage {
        address owner;
        Engine engine;
        uint256 loanId;
        uint256 deposit;
        uint256 landId;
        uint256 landCost;
        Status status;
        Type morateType;
        // ERC-721
        address approvedTransfer;
    }

    uint256 internal flagReceiveLand;
    Mortgage[] public mortgages;

    uint256 public totalMortgages;
    mapping(address => uint256) private balances;
    mapping(address => mapping(address => bool)) private operators;
    mapping(uint256 => uint256) public mortgageByLandId;

    function totalSupply() public view returns (uint256) {
        return totalMortgages;
    }

    function balanceOf(address _owner) public view returns (uint256) {
        return balances[_owner];
    } 

    function url() public view returns (string) {
        return "";
    }

    function tokenMetadata(uint256 _tokenId) public view returns (string) {
        return "";
    }

    function cost(address, uint256, bytes, bytes) public view returns (uint256) {
        return 0;
    }

    /**
        @notices Requests a mortage on a already owned parcel
    */
    function requestMortgage(Engine engine, uint256 loanId, uint256 landId) public returns (uint256 id) {
        // Validate the associated loan
        require(engine.getCurrency(loanId) == MANA_CURRENCY);
        require(engine.getBorrower(loanId) == msg.sender);
        require(engine.getStatus(loanId) == Engine.Status.initial);
        require(engine.isApproved(loanId));

        // Flag and check the receive of that parcel
        flagReceiveLand = landId;
        land.transferFrom(msg.sender, this, landId);
        require(flagReceiveLand == 0);
        // Lock the parcel
        lockERC721(land, landId);

        // Create the liability
        id = mortgages.push(Mortgage({
            owner: msg.sender,
            engine: engine,
            loanId: loanId,
            deposit: 0,
            landId: landId,
            landCost: 0,
            status: Status.Pending,
            approvedTransfer: 0x0,
            morateType: Type.Loan
        })) - 1;

        RequestedMortgage({
            _id: id,
            _type: Type.Loan,
            _borrower: msg.sender,
            _engine: engine,
            _loanId: loanId,
            _landId: landId,
            _deposit: 0
        });
    }

    /**
        @notices Request a mortage to buy a new loan
    */
    function requestMortgage(Engine engine, uint256 loanId, uint256 deposit, uint256 landId) public returns (uint256 id) {
        // Validate the associated loan
        require(engine.getCurrency(loanId) == MANA_CURRENCY);
        require(engine.getBorrower(loanId) == msg.sender);
        require(engine.getStatus(loanId) == Engine.Status.initial);
        require(engine.isApproved(loanId));
        require(rcn.allowance(msg.sender, this) >= REQUIRED_ALLOWANCE);

        // Get the current parcel cost
        uint256 landCost;
        (, , landCost, ) = landMarket.auctionByAssetId(landId);
        uint256 loanAmount = engine.getAmount(loanId);

        // We expect a 10% extra for convertion losses
        // the remaining will be sent to the borrower
        require((loanAmount + deposit) >= ((landCost / 10) * 11));

        // Pull the deposit and lock the tokens
        require(mana.transferFrom(msg.sender, this, deposit));
        lockERC20(mana, deposit);

        // Create the liability
        id = mortgages.push(Mortgage({
            owner: msg.sender,
            engine: engine,
            loanId: loanId,
            deposit: deposit,
            landId: landId,
            landCost: landCost,
            status: Status.Pending,
            approvedTransfer: 0x0,
            morateType: Type.Buy
        })) - 1;

        RequestedMortgage({
            _id: id,
            _type: Type.Buy,
            _borrower: msg.sender,
            _engine: engine,
            _loanId: loanId,
            _landId: landId,
            _deposit: deposit
        });
    }

    /**
        @notices Cancels an existing mortgage
    */
    function cancelMortgage(uint256 id) public returns (bool) {
        Mortgage storage mortgage = mortgages[id];
        
        // Only the owner of the mortgage and if the mortgage is pending
        require(mortgage.owner == msg.sender);
        require(mortgage.status == Status.Pending);
        
        mortgage.status = Status.Canceled;

        if (mortgage.morateType == Type.Buy) {
            // Transfer the deposit back to the borrower
            mana.transferFrom(this, msg.sender, mortgage.deposit);
            unlockERC20(mana, mortgage.deposit);
        } else {
            // Transfer the parcel
            land.transferFrom(this, msg.sender, mortgage.landId);
            unlockERC721(land, mortgage.landId);
        }

        CanceledMortgage(id);
        return true;
    }

    /**
        @notices Request the cosign of a loan
        @dev Required for RCN Cosigner compliance
    */
    function requestCosign(Engine engine, uint256 index, bytes data, bytes oracleData) public returns (bool) {
        // The first word of the data MUST contain the index of the target mortgage
        Mortgage storage mortgage = mortgages[uint256(readBytes32(data, 0))];

        // Validate that the loan matches with the mortgage
        // and the mortgage is still pending
        require(mortgage.engine == engine);
        require(mortgage.loanId == index);
        require(mortgage.status == Status.Pending);

        mortgage.status = Status.Ongoing;

        // Mint mortgage ERC721 Token
        totalMortgages++;
        balances[mortgage.owner]++;
        Transfer(0x0, mortgage.owner, uint256(readBytes32(data, 0)));

        // Transfer the amount of the loan in RCN to this contract
        uint256 loanAmount = convertRate(engine.getOracle(index), engine.getCurrency(index), oracleData, engine.getAmount(index));
        require(rcn.transferFrom(mortgage.owner, this, loanAmount));
        
        // Convert the RCN into MANA using KyberNetwork
        // and save the received MANA
        require(rcn.approve(kyberNetwork, loanAmount));
        uint256 boughtMana = kyberNetwork.trade(rcn, loanAmount, mana, this, 10 ** 30, 0, this);
        require(rcn.approve(kyberNetwork, 0));

        // If the mortgage is of type Loan, this will remain 0
        uint256 currentLandCost;

        // Buy land and retrieve the cost if required by the type of mortgage
        if (mortgage.morateType == Type.Buy) {
            // Load the new cost of the parcel, it may be changed
            (, , currentLandCost, ) = landMarket.auctionByAssetId(mortgage.landId);

            // If the parcel is more expensive than before, cancel the transaction
            require(currentLandCost <= mortgage.landCost);

            // Buy the land and lock it into the mortgage contract
            flagReceiveLand = mortgage.landId;
            require(mana.approve(landMarket, currentLandCost));
            landMarket.executeOrder(mortgage.landId, currentLandCost);
            require(mana.approve(landMarket, 0));
            require(flagReceiveLand == 0);
            lockERC721(land, mortgage.landId);
        }

        // Calculate the remaining amount to send to the borrower and 
        // check that we didn't expend any contract funds.
        uint256 totalMana = safeAdd(boughtMana, mortgage.deposit);
        uint256 rest = safeSubtract(totalMana, currentLandCost);

        // Return rest MANA
        require(mana.transfer(mortgage.owner, rest));

        // Unlock MANA from deposit
        unlockERC20(mana, mortgage.deposit);

        // Cosign contract
        require(mortgage.engine.cosign(index, 0));

        // Save mortgage id registry
        mortgageByLandId[mortgage.landId] = uint256(readBytes32(data, 0));

        // Emit mortgage event
        StartedMortgage(uint256(readBytes32(data, 0)));

        return true;
    }

    /**
        @notices Claims the mortgage by the lender/borrower
    */
    function claim(address, uint256 id, bytes) public returns (bool) {
        Mortgage storage mortgage = mortgages[id];
        
        // Validate that the mortgage wasn't claimed
        require(mortgage.status == Status.Ongoing);

        uint256 loanId = mortgage.loanId;
        
        // Delete mortgage id registry
        delete mortgageByLandId[mortgage.landId];
        
        // ERC721 Delete asset
        totalMortgages--;
        balances[mortgage.owner]--;
        Transfer(mortgage.owner, 0x0, id);
        
        if (mortgage.owner == msg.sender) {
            // Check that the loan is paid
            require(mortgage.engine.getStatus(loanId) == Engine.Status.paid ||
                mortgage.engine.getStatus(loanId) == Engine.Status.destroyed);
            mortgage.status = Status.Paid;
            // Transfer the parcel to the borrower
            land.transferFrom(this, mortgage.owner, mortgage.landId);
            unlockERC721(land, mortgage.landId);
            PaidMortgage(id);
            return true;
        } else if (mortgage.engine.ownerOf(loanId) == msg.sender) {
            // Check if the loan is defaulted
            require(isDefaulted(mortgage.engine, loanId));
            mortgage.status = Status.Defaulted;
            // Transfer the parcel to the lender
            land.transferFrom(this, msg.sender, mortgage.landId);
            unlockERC721(land, mortgage.landId);
            DefaultedMortgage(id);
            return true;
        }
    }

    /**
        @notices Defines a custom logic that determines if a loan is defaulted or not.

        @param index Index of the loan

        @return true if the loan is considered defaulted
    */
    function isDefaulted(Engine engine, uint256 index) public view returns (bool) {
        return engine.getStatus(index) == Engine.Status.lent &&
            safeAdd(engine.getDueTime(index), 7 days) <= block.timestamp;
    }

    function transferFrom(address from, address to, uint256 id) public returns (bool) {
        require(mortgages[id].owner == from);
        return transfer(to, id);
    }

    function takeOwnership(uint256 id) public returns (bool) {
        return transfer(msg.sender, id);
    }

    function transfer(address to, uint256 id) public returns (bool) {
        require(to != address(0));
        Mortgage storage mortgage = mortgages[id];
        require(mortgage.status == Status.Ongoing);
        require(msg.sender == mortgage.owner || msg.sender == mortgage.approvedTransfer || operators[mortgage.owner][msg.sender]);
        Transfer(msg.sender, to, id);
        mortgage.owner = to;
        mortgage.approvedTransfer = address(0);
        return true;
    }

    function approve(address operator, uint256 id) public returns (bool) {
        Mortgage storage mortgage = mortgages[id];
        require(msg.sender == mortgage.owner);
        mortgage.approvedTransfer = operator;
        Approval(msg.sender, operator, id);
        return true;
    }

    function setApprovalForAll(address operator, bool approved) public returns (bool) {
        operators[msg.sender][operator] = approved;
        ApprovalForAll(msg.sender, operator, approved);
        return true;
    }

    function getApproved(uint256 id) public view returns (address) {
        return mortgages[id].approvedTransfer;
    }

    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return operators[owner][operator];
    }

    function ownerOf(uint256 id) public view returns (address) {
        return mortgages[id].owner;
    }

    function onERC721Received(uint256 _tokenId, address _from, bytes data) public returns (bytes4) {
        return onERC721Received(_from, _tokenId, data);
    }

    function onERC721Received(address _from, uint256 _tokenId, bytes data) public returns (bytes4) {
        if (msg.sender == address(land) && flagReceiveLand == _tokenId) {
            flagReceiveLand = 0;
            return bytes4(keccak256("onERC721Received(address,uint256,bytes)"));
        }
    }
    
    function updateLandData(uint256 id, string data) public returns (bool) {
        Mortgage memory mortgage = mortgages[id];
        require(msg.sender == mortgage.owner);
        int256 x;
        int256 y;
        (x, y) = land.decodeTokenId(mortgage.landId);
        land.updateLandData(x, y, data);
        return true;
    }

    function convertRate(Oracle oracle, bytes32 currency, bytes data, uint256 amount) internal returns (uint256) {
        if (oracle == address(0)) {
            return amount;
        } else {
            uint256 rate;
            uint256 decimals;
            
            (rate, decimals) = oracle.getRate(currency, data);

            require(decimals <= RCN_DECIMALS);
            return (safeMult(safeMult(amount, rate), (10**(RCN_DECIMALS-decimals)))) / PRECISION;
        }
    }

}