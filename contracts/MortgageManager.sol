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
    function ownerOf(uint256 landID) public view returns (address);
}

/**
    @notice The contract is used to handle all the lifetime of a mortgage, uses RCN for the Loan and Decentraland for the parcels. 

    Implements the Cosigner interface of RCN, and when is tied to a loan it creates a new ERC721 to handle the ownership of the mortgage.

    When the loan is resolved (paid, pardoned or defaulted), the mortgaged parcel can be recovered. 

    Uses a token converter to buy the Decentraland parcel with MANA using the RCN tokens received.
*/
contract MortgageManager is Cosigner, ERC721Base, ERCLockable, BytesUtils {
    uint256 constant internal PRECISION = (10**18);
    uint256 constant internal RCN_DECIMALS = 18;

    bytes32 public constant MANA_CURRENCY = 0x4d414e4100000000000000000000000000000000000000000000000000000000;
    uint256 public constant REQUIRED_ALLOWANCE = 1000000000 * 10**18;

    function name() public pure returns (string _name) {
        _name = "Decentraland RCN Mortgage";
    }

    function symbol() public pure returns (string _symbol) {
        _symbol = "LAND-RCN-Mortgage";
    }

    event RequestedMortgage(uint256 _id, address _borrower, address _engine, uint256 _loanId, uint256 _landId, uint256 _deposit, address _tokenConverter);
    event StartedMortgage(uint256 _id);
    event CanceledMortgage(address _from, uint256 _id);
    event PaidMortgage(address _from, uint256 _id);
    event DefaultedMortgage(uint256 _id);
    event UpdatedLandData(address _updater, uint256 _parcel, string _data);
    event SetCreator(address _creator, bool _status);

    Token public rcn;
    Token public mana;
    Land public land;
    LandMarket public landMarket;
    
    constructor(Token _rcn, Token _mana, Land _land, LandMarket _landMarket) public {
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

    function url() public view returns (string) {
        return "";
    }

    /**
        @notice Sets a new third party creator
        
        The third party creator can request loans for other borrowers. The creator should be a trusted contract, it could potentially take funds.
    
        @param creator Address of the creator
        @param authorized Enables or disables the permission

        @return true If the operation was executed
    */
    function setCreator(address creator, bool authorized) external onlyOwner returns (bool) {
        emit SetCreator(creator, authorized);
        creators[creator] = authorized;
        return true;
    }

    /**
        @notice Returns the cost of the cosigner

        This cosigner does not have any risk or maintenance cost, so its free.

        @return 0, because it's free
    */
    function cost(address, uint256, bytes, bytes) public view returns (uint256) {
        return 0;
    }

    /**
        @notice Requests a mortgage with a loan identifier

        @dev The loan should exist in the designated engine

        @param engine RCN Engine
        @param loanIdentifier Identifier of the loan asociated with the mortgage
        @param deposit MANA to cover part of the cost of the parcel
        @param landId ID of the parcel to buy with the mortgage
        @param tokenConverter Token converter used to exchange RCN - MANA

        @return id The id of the mortgage
    */
    function requestMortgage(
        Engine engine,
        bytes32 loanIdentifier,
        uint256 deposit,
        uint256 landId,
        TokenConverter tokenConverter
    ) external returns (uint256 id) {
        return requestMortgageId(engine, engine.identifierToIndex(loanIdentifier), deposit, landId, tokenConverter);
    }

    /**
        @notice Request a mortgage with a loan id

        @dev The loan should exist in the designated engine

        @param engine RCN Engine
        @param loanId Id of the loan asociated with the mortgage
        @param deposit MANA to cover part of the cost of the parcel
        @param landId ID of the parcel to buy with the mortgage
        @param tokenConverter Token converter used to exchange RCN - MANA

        @return id The id of the mortgage
    */
    function requestMortgageId(
        Engine engine,
        uint256 loanId,
        uint256 deposit,
        uint256 landId,
        TokenConverter tokenConverter
    ) public returns (uint256 id) {
        // Validate the associated loan
        require(engine.getCurrency(loanId) == MANA_CURRENCY, "Loan currency is not MANA");
        address borrower = engine.getBorrower(loanId);
        require(engine.getStatus(loanId) == Engine.Status.initial, "Loan status is not inital");
        require(msg.sender == engine.getBorrower(loanId) ||
               (msg.sender == engine.getCreator(loanId) && creators[msg.sender]),
            "Creator should be borrower or authorized");
        require(engine.isApproved(loanId), "Loan is not approved");
        require(rcn.allowance(borrower, this) >= REQUIRED_ALLOWANCE, "Manager cannot handle borrower's funds");
        require(tokenConverter != address(0), "Token converter not defined");
        require(loanToLiability[engine][loanId] == 0, "Liability for loan already exists");

        // Get the current parcel cost
        uint256 landCost;
        (, , landCost, ) = landMarket.auctionByAssetId(landId);
        uint256 loanAmount = engine.getAmount(loanId);

        // We expect a 10% extra for convertion losses
        // the remaining will be sent to the borrower
        require((loanAmount + deposit) >= ((landCost / 10) * 11), "Not enought total amount");

        // Pull the deposit and lock the tokens
        require(mana.transferFrom(msg.sender, this, deposit), "Error pulling mana");
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
            _deposit: deposit,
            _tokenConverter: tokenConverter
        });
    }

    /**
        @notice Cancels an existing mortgage
        @dev The mortgage status should be pending
        @param id Id of the mortgage
        @return true If the operation was executed

    */
    function cancelMortgage(uint256 id) external returns (bool) {
        Mortgage storage mortgage = mortgages[id];
        
        // Only the owner of the mortgage and if the mortgage is pending
        require(msg.sender == mortgage.owner, "Only the owner can cancel the mortgage");
        require(mortgage.status == Status.Pending, "The mortgage is not pending");
        
        mortgage.status = Status.Canceled;

        // Transfer the deposit back to the borrower
        require(mana.transfer(msg.sender, mortgage.deposit), "Error returning MANA");
        unlockERC20(mana, mortgage.deposit);

        emit CanceledMortgage(msg.sender, id);
        return true;
    }

    /**
        @notice Request the cosign of a loan

        Buys the parcel and locks its ownership until the loan status is resolved.
        Emits an ERC721 to manage the ownership of the mortgaged property.
    
        @param engine Engine of the loan
        @param index Index of the loan
        @param data Data with the mortgage id
        @param oracleData Oracle data to calculate the loan amount

        @return true If the cosign was performed
    */
    function requestCosign(Engine engine, uint256 index, bytes data, bytes oracleData) public returns (bool) {
        // The first word of the data MUST contain the index of the target mortgage
        Mortgage storage mortgage = mortgages[uint256(readBytes32(data, 0))];
        
        // Validate that the loan matches with the mortgage
        // and the mortgage is still pending
        require(mortgage.engine == engine, "Engine does not match");
        require(mortgage.loanId == index, "Loan id does not match");
        require(mortgage.status == Status.Pending, "Mortgage is not pending");

        // Update the status of the mortgage to avoid reentrancy
        mortgage.status = Status.Ongoing;

        // Mint mortgage ERC721 Token
        _generate(uint256(readBytes32(data, 0)), mortgage.owner);

        // Transfer the amount of the loan in RCN to this contract
        uint256 loanAmount = convertRate(engine.getOracle(index), engine.getCurrency(index), oracleData, engine.getAmount(index));
        require(rcn.transferFrom(mortgage.owner, this, loanAmount), "Error pulling RCN from borrower");
        
        // Convert the RCN into MANA using the designated
        // and save the received MANA
        uint256 boughtMana = convertSafe(mortgage.tokenConverter, rcn, mana, loanAmount);
        delete mortgage.tokenConverter;

        // Load the new cost of the parcel, it may be changed
        uint256 currentLandCost;
        (, , currentLandCost, ) = landMarket.auctionByAssetId(mortgage.landId);
        require(currentLandCost <= mortgage.landCost, "Parcel is more expensive than expected");
        
        // Buy the land and lock it into the mortgage contract
        require(mana.approve(landMarket, currentLandCost));
        flagReceiveLand = mortgage.landId;
        landMarket.executeOrder(mortgage.landId, currentLandCost);
        require(mana.approve(landMarket, 0));
        require(flagReceiveLand == 0, "ERC721 callback not called");
        require(land.ownerOf(mortgage.landId) == address(this), "Error buying parcel");
        lockERC721(land, mortgage.landId);

        // Calculate the remaining amount to send to the borrower and 
        // check that we didn't expend any contract funds.
        uint256 totalMana = safeAdd(boughtMana, mortgage.deposit);        
        uint256 rest = safeSubtract(totalMana, currentLandCost);

        // Return rest of MANA to the owner
        require(mana.transfer(mortgage.owner, rest), "Error returning MANA");

        // Unlock MANA from deposit
        unlockERC20(mana, mortgage.deposit);
        
        // Cosign contract, 0 is the RCN required
        require(mortgage.engine.cosign(index, 0), "Error performing cosign");
        
        // Save mortgage id registry
        mortgageByLandId[mortgage.landId] = uint256(readBytes32(data, 0));

        // Emit mortgage event
        emit StartedMortgage(uint256(readBytes32(data, 0)));

        return true;
    }

    /**
        @notice Converts tokens using a token converter
        @dev Does not trust the token converter, validates the return amount
        @param converter Token converter used
        @param from Tokens to sell
        @param to Tokens to buy
        @param amount Amount to sell
        @return bought Bought amount
    */
    function convertSafe(
        TokenConverter converter,
        Token from,
        Token to,
        uint256 amount
    ) internal returns (uint256 bought) {
        require(from.approve(converter, amount));
        uint256 prevBalance = to.balanceOf(this);
        bought = converter.convert(from, to, amount, 1);
        require(safeSubtract(to.balanceOf(this), prevBalance) >= bought, "Bought amount incorrect");
        require(from.approve(converter, 0));
    }

    /**
        @notice Claims the mortgage when the loan status is resolved and transfers the ownership of the parcel to which corresponds.

        @dev Deletes the mortgage ERC721

        @param engine RCN Engine
        @param loanId Loan ID
        
        @return true If the claim succeded
    */
    function claim(address engine, uint256 loanId, bytes) external returns (bool) {
        uint256 mortgageId = loanToLiability[engine][loanId];
        Mortgage storage mortgage = mortgages[mortgageId];

        // Validate that the mortgage wasn't claimed
        require(mortgage.status == Status.Ongoing, "Mortgage not ongoing");
        require(mortgage.loanId == loanId, "Mortgage don't match loan id");
        
        // Unlock the Parcel token
        unlockERC721(land, mortgage.landId);

        if (mortgage.engine.getStatus(loanId) == Engine.Status.paid || mortgage.engine.getStatus(loanId) == Engine.Status.destroyed) {
            // The mortgage is paid
            require(_isAuthorized(msg.sender, mortgageId), "Sender not authorized");

            mortgage.status = Status.Paid;
            // Transfer the parcel to the borrower
            land.safeTransferFrom(this, msg.sender, mortgage.landId);
            emit PaidMortgage(msg.sender, mortgageId);
        } else if (isDefaulted(mortgage.engine, loanId)) {
            // The mortgage is defaulted
            require(msg.sender == mortgage.engine.ownerOf(loanId), "Sender not lender");
            
            mortgage.status = Status.Defaulted;
            // Transfer the parcel to the lender
            land.safeTransferFrom(this, msg.sender, mortgage.landId);
            emit DefaultedMortgage(mortgageId);
        } else {
            revert("Mortgage not defaulted/paid");
        }

        // ERC721 Delete asset
        _destroy(mortgageId);

        // Delete mortgage id registry
        delete mortgageByLandId[mortgage.landId];

        return true;
    }

    /**
        @notice Defines a custom logic that determines if a loan is defaulted or not.

        @param engine RCN Engines
        @param index Index of the loan

        @return true if the loan is considered defaulted
    */
    function isDefaulted(Engine engine, uint256 index) public view returns (bool) {
        return engine.getStatus(index) == Engine.Status.lent &&
            safeAdd(engine.getDueTime(index), 7 days) <= block.timestamp;
    }

    /**
        @dev An alternative version of the ERC721 callback, required by a bug in the parcels contract
    */
    function onERC721Received(uint256 _tokenId, address _from, bytes data) external returns (bytes4) {
        if (msg.sender == address(land) && flagReceiveLand == _tokenId) {
            flagReceiveLand = 0;
            return bytes4(keccak256("onERC721Received(address,uint256,bytes)"));
        }
    }

    /**
        @notice Callback used to accept the ERC721 parcel tokens

        @dev Only accepts tokens if flag is set to tokenId, resets the flag when called
    */
    function onERC721Received(address _from, uint256 _tokenId, bytes data) external returns (bytes4) {
        if (msg.sender == address(land) && flagReceiveLand == _tokenId) {
            flagReceiveLand = 0;
            return bytes4(keccak256("onERC721Received(address,uint256,bytes)"));
        }
    }

    /**
        @dev Reads data from a bytes array
    */
    function getData(uint256 id) public pure returns (bytes o) {
        assembly {
            o := mload(0x40)
            mstore(0x40, add(o, and(add(add(32, 0x20), 0x1f), not(0x1f))))
            mstore(o, 32)
            mstore(add(o, 32), id)
        }
    }
    
    /**
        @notice Enables the owner of a parcel to update the data field

        @param id Id of the mortgage
        @param data New data

        @return true If data was updated
    */
    function updateLandData(uint256 id, string data) external returns (bool) {
        Mortgage memory mortgage = mortgages[id];
        require(_isAuthorized(msg.sender, id), "Sender not authorized");
        int256 x;
        int256 y;
        (x, y) = land.decodeTokenId(mortgage.landId);
        land.updateLandData(x, y, data);
        emit UpdatedLandData(msg.sender, id, data);
        return true;
    }

    /**
        @dev Replica of the convertRate function of the RCN Engine, used to apply the oracle rate
    */
    function convertRate(Oracle oracle, bytes32 currency, bytes data, uint256 amount) internal returns (uint256) {
        if (oracle == address(0)) {
            return amount;
        } else {
            uint256 rate;
            uint256 decimals;
            
            (rate, decimals) = oracle.getRate(currency, data);

            require(decimals <= RCN_DECIMALS, "Decimals exceeds max decimals");
            return (safeMult(safeMult(amount, rate), (10**(RCN_DECIMALS-decimals)))) / PRECISION;
        }
    }
}