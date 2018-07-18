pragma solidity ^0.4.19;

import "./interfaces/Token.sol";
import "./interfaces/Cosigner.sol";
import "./interfaces/Engine.sol";
import "./interfaces/ERC721.sol";
import "./utils/ERCLockable.sol";
import "./utils/BytesUtils.sol";
import "./interfaces/Oracle.sol";
import "./interfaces/TokenConverter.sol";
import "./ERC721Base.sol";

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

contract Land is ERC721 {
    function updateLandData(int x, int y, string data) public;
    function decodeTokenId(uint value) view public returns (int, int);
    function safeTransferFrom(address from, address to, uint256 assetId) public;
}

contract MortgageManager is Cosigner, ERC721Base, ERCLockable, BytesUtils {
    uint256 constant internal PRECISION = (10**18);
    uint256 constant internal RCN_DECIMALS = 18;

    bytes32 public constant MANA_CURRENCY = 0x4d414e4100000000000000000000000000000000000000000000000000000000;
    uint256 public constant REQUIRED_ALLOWANCE = 1000000000 * 10**18;

    function name() public view returns (string _name) {
        _name = "Decentraland RCN Mortgage";
    }

    function symbol() public view returns (string _symbol) {
        _symbol = "LAND-RCN-Mortgage";
    }

    event RequestedMortgage(uint256 _id, address _borrower, address _engine, uint256 _loanId, uint256 _landId, uint256 _deposit);
    event StartedMortgage(uint256 _id);
    event CanceledMortgage(uint256 _id);
    event PaidMortgage(uint256 _id);
    event DefaultedMortgage(uint256 _id);

    Token public rcn;
    Token public mana;
    Land public land;
    LandMarket public landMarket;
    
    function MortgageManager(Token _rcn, Token _mana, Land _land, LandMarket _landMarket) public {
        setTokenType(mana, ERCLockable.TokenType.ERC20);
        setTokenType(rcn, ERCLockable.TokenType.ERC20);
        setTokenType(land, ERCLockable.TokenType.ERC721);
        rcn = _rcn;
        mana = _mana;
        land = _land;
        landMarket = _landMarket;
        mortgages.length++;
    }

    enum Status { Pending, Ongoing, Canceled, Paid, Defaulted }

    struct Mortgage {
        address owner;
        Engine engine;
        uint256 loanId;
        uint256 deposit;
        uint256 landId;
        uint256 landCost;
        Status status;
        // ERC-721
        TokenConverter tokenConverter;
    }

    uint256 internal flagReceiveLand;

    Mortgage[] public mortgages;

    mapping(address => bool) public creators;

    mapping(uint256 => uint256) public mortgageByLandId;
    mapping(address => mapping(uint256 => uint256)) public loanToLiability;

    function setCreator(address creator, bool authorized) public onlyOwner returns (bool) {
        creators[creator] = authorized;
    }

    function url() public view returns (string) {
        return "";
    }

    function cost(address, uint256, bytes, bytes) public view returns (uint256) {
        return 0;
    }

    function requestMortgage(Engine engine, bytes32 loanIdentifier, uint256 deposit, uint256 landId, TokenConverter tokenConverter) public returns (uint256 id) {
        return requestMortgageId(engine, engine.identifierToIndex(loanIdentifier), deposit, landId, tokenConverter);
    }

    /**
        @notice Request a mortgage to buy a new loan
    */
    function requestMortgageId(Engine engine, uint256 loanId, uint256 deposit, uint256 landId, TokenConverter tokenConverter) public returns (uint256 id) {
        // Validate the associated loan
        require(engine.getCurrency(loanId) == MANA_CURRENCY);
        address borrower = engine.getBorrower(loanId);
        require(engine.getStatus(loanId) == Engine.Status.initial);
        require(msg.sender == borrower || (msg.sender == engine.getCreator(loanId) && creators[msg.sender]));
        require(engine.isApproved(loanId));
        require(rcn.allowance(borrower, this) >= REQUIRED_ALLOWANCE);
        require(tokenConverter != address(0));
        require(loanToLiability[engine][loanId] == 0);

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
            owner: borrower,
            engine: engine,
            loanId: loanId,
            deposit: deposit,
            landId: landId,
            landCost: landCost,
            status: Status.Pending,
            tokenConverter: tokenConverter
        })) - 1;

        loanToLiability[engine][loanId] = id;

        emit RequestedMortgage({
            _id: id,
            _borrower: borrower,
            _engine: engine,
            _loanId: loanId,
            _landId: landId,
            _deposit: deposit
        });
    }

    /**
        @notice Cancels an existing mortgage
    */
    function cancelMortgage(uint256 id) public returns (bool) {
        Mortgage storage mortgage = mortgages[id];
        
        // Only the owner of the mortgage and if the mortgage is pending
        require(mortgage.owner == msg.sender);
        require(mortgage.status == Status.Pending);
        
        mortgage.status = Status.Canceled;

        // Transfer the deposit back to the borrower
        require(mana.transfer(msg.sender, mortgage.deposit));
        unlockERC20(mana, mortgage.deposit);

        emit CanceledMortgage(id);
        return true;
    }

    /**
        @notice Request the cosign of a loan
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
        _generate(uint256(readBytes32(data, 0)), mortgage.owner);

        // Transfer the amount of the loan in RCN to this contract
        uint256 loanAmount = convertRate(engine.getOracle(index), engine.getCurrency(index), oracleData, engine.getAmount(index));
        require(rcn.transferFrom(mortgage.owner, this, loanAmount));
        
        // Convert the RCN into MANA using the designated
        // and save the received MANA
        require(rcn.approve(mortgage.tokenConverter, loanAmount));
        uint256 boughtMana = mortgage.tokenConverter.convert(rcn, mana, loanAmount, 1);
        delete mortgage.tokenConverter;

        // If the mortgage is of type Loan, this will remain 0
        uint256 currentLandCost;

        // Load the new cost of the parcel, it may be changed
        (, , currentLandCost, ) = landMarket.auctionByAssetId(mortgage.landId);
        require(currentLandCost <= mortgage.landCost);
        
        // Buy the land and lock it into the mortgage contract
        require(mana.approve(landMarket, currentLandCost));
        flagReceiveLand = mortgage.landId;
        landMarket.executeOrder(mortgage.landId, currentLandCost);
        require(mana.approve(landMarket, 0));
        require(flagReceiveLand == 0);
        lockERC721(land, mortgage.landId);

        // Calculate the remaining amount to send to the borrower and 
        // check that we didn't expend any contract funds.
        uint256 totalMana = safeAdd(boughtMana, mortgage.deposit);        
        uint256 rest = safeSubtract(totalMana, currentLandCost);

        // Return rest MANAowner
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
        @notice Claims the mortgage by the lender/borrower
    */
    function claim(address engine, uint256 loanId, bytes) public returns (bool) {
        uint256 mortgageId = loanToLiability[engine][loanId];
        Mortgage storage mortgage = mortgages[mortgageId];

        // Validate that the mortgage wasn't claimed
        require(mortgage.status == Status.Ongoing);
        require(mortgage.loanId == loanId);
        
        // ERC721 Delete asset
        _destroy(mortgageId);

        // Delete mortgage id registry
        delete mortgageByLandId[mortgage.landId];

        // Unlock the Parcel token
        unlockERC721(land, mortgage.landId);

        if (mortgage.owner == msg.sender) {
            // Check that the loan is paid
            require(mortgage.engine.getStatus(loanId) == Engine.Status.paid || mortgage.engine.getStatus(loanId) == Engine.Status.destroyed);
            mortgage.status = Status.Paid;
            // Transfer the parcel to the borrower
            land.safeTransferFrom(this, mortgage.owner, mortgage.landId);
            emit PaidMortgage(mortgageId);
            return true;
        } else if (mortgage.engine.ownerOf(loanId) == msg.sender) {
            // Check if the loan is defaulted
            require(isDefaulted(mortgage.engine, loanId));
            mortgage.status = Status.Defaulted;
            // Transfer the parcel to the lender
            land.safeTransferFrom(this, msg.sender, mortgage.landId);
            emit DefaultedMortgage(mortgageId);
            return true;
        } else {
            revert();
        }
    }

    /**
        @notice Defines a custom logic that determines if a loan is defaulted or not.

        @param index Index of the loan

        @return true if the loan is considered defaulted
    */
    function isDefaulted(Engine engine, uint256 index) public view returns (bool) {
        return engine.getStatus(index) == Engine.Status.lent &&
            safeAdd(engine.getDueTime(index), 7 days) <= block.timestamp;
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

    function getData(uint256 id) pure returns (bytes o) {
        assembly {
            o := mload(0x40)
            mstore(0x40, add(o, and(add(add(32, 0x20), 0x1f), not(0x1f))))
            mstore(o, 32)
            mstore(add(o, 32), id)
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
