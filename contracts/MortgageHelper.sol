pragma solidity ^0.4.19;

import "./interfaces/Token.sol";
import "./interfaces/TokenConverter.sol";
import "./MortgageManager.sol";
import "./ConverterRamp.sol";
import "./utils/LrpSafeMath.sol";
import "./utils/Ownable.sol";

/**
    @notice Set of functions to operate the mortgage manager in less transactions
*/
contract MortgageHelper is Ownable {
    using LrpSafeMath for uint256;

    MortgageManager public mortgageManager;
    NanoLoanEngine public nanoLoanEngine;
    Token public rcn;
    Token public mana;
    LandMarket public landMarket;
    TokenConverter public tokenConverter;
    ConverterRamp public converterRamp;

    address public manaOracle;
    uint256 public requiredTotal = 105;

    uint256 public rebuyThreshold = 0.001 ether;
    uint256 public marginSpend = 500;
    uint256 public maxSpend = 300;

    bytes32 public constant MANA_CURRENCY = 0x4d414e4100000000000000000000000000000000000000000000000000000000;

    event NewMortgage(address borrower, uint256 loanId, uint256 landId, uint256 mortgageId);
    event PaidLoan(address engine, uint256 loanId, uint256 amount);
    event SetConverterRamp(address _prev, address _new);
    event SetTokenConverter(address _prev, address _new);
    event SetRebuyThreshold(uint256 _prev, uint256 _new);
    event SetMarginSpend(uint256 _prev, uint256 _new);
    event SetMaxSpend(uint256 _prev, uint256 _new);
    event SetRequiredTotal(uint256 _prev, uint256 _new);

    constructor(
        MortgageManager _mortgageManager,
        NanoLoanEngine _nanoLoanEngine,
        address _manaOracle,
        TokenConverter _tokenConverter,
        ConverterRamp _converterRamp
    ) public {
        mortgageManager = _mortgageManager;
        nanoLoanEngine = _nanoLoanEngine;
        rcn = _mortgageManager.rcn();
        mana = _mortgageManager.mana();
        landMarket = _mortgageManager.landMarket();
        manaOracle = _manaOracle;
        tokenConverter = _tokenConverter;
        converterRamp = _converterRamp;

        emit SetConverterRamp(converterRamp, _converterRamp);
        emit SetTokenConverter(tokenConverter, _tokenConverter);

        emit SetMaxSpend(0, maxSpend);
        emit SetMarginSpend(0, marginSpend);
        emit SetRebuyThreshold(0, rebuyThreshold);
        emit SetRequiredTotal(0, requiredTotal);
    }

    /**
        @dev Creates a loan using an array of parameters

        @param params 0 - Ammount
                      1 - Interest rate
                      2 - Interest rate punitory
                      3 - Dues in
                      4 - Cancelable at
                      5 - Expiration of request

        @param metadata Loan metadata

        @return Id of the loan

    */
    function createLoan(uint256[6] memory params, string metadata) internal returns (uint256) {
        return nanoLoanEngine.createLoan(
            manaOracle,
            msg.sender,
            MANA_CURRENCY,
            params[0],
            params[1],
            params[2],
            params[3],
            params[4],
            params[5],
            metadata
        );
    }

    /**
        @notice Sets a max amount to expend when performing the payment
        @dev Only owner
        @param _maxSpend New maxSPend value
        @return true If the change was made
    */
    function setMaxSpend(uint256 _maxSpend) external onlyOwner returns (bool) {
        emit SetMaxSpend(maxSpend, _maxSpend);
        maxSpend = _maxSpend;
        return true;
    }

    /**
        @notice Sets required total of the mortgage
        @dev Only owner
        @param _requiredTotal New requiredTotal value
        @return true If the change was made
    */
    function setRequiredTotal(uint256 _requiredTotal) external onlyOwner returns (bool) {
        emit SetRequiredTotal(requiredTotal, _requiredTotal);
        requiredTotal = _requiredTotal;
        return true;
    }


    /**
        @notice Sets a new converter ramp to delegate the pay of the loan
        @dev Only owner
        @param _converterRamp Address of the converter ramp contract
        @return true If the change was made
    */
    function setConverterRamp(ConverterRamp _converterRamp) external onlyOwner returns (bool) {
        emit SetConverterRamp(converterRamp, _converterRamp);
        converterRamp = _converterRamp;
        return true;
    }

    /**
        @notice Sets a new min of tokens to rebuy when paying a loan
        @dev Only owner
        @param _rebuyThreshold New rebuyThreshold value
        @return true If the change was made
    */
    function setRebuyThreshold(uint256 _rebuyThreshold) external onlyOwner returns (bool) {
        emit SetRebuyThreshold(rebuyThreshold, _rebuyThreshold);
        rebuyThreshold = _rebuyThreshold;
        return true;
    }

    /**
        @notice Sets how much the converter ramp is going to oversell to cover fees and gaps
        @dev Only owner
        @param _marginSpend New marginSpend value
        @return true If the change was made
    */
    function setMarginSpend(uint256 _marginSpend) external onlyOwner returns (bool) {
        emit SetMarginSpend(marginSpend, _marginSpend);
        marginSpend = _marginSpend;
        return true;
    }

    /**
        @notice Sets the token converter used to convert the MANA into RCN when performing the payment
        @dev Only owner
        @param _tokenConverter Address of the tokenConverter contract
        @return true If the change was made
    */
    function setTokenConverter(TokenConverter _tokenConverter) external onlyOwner returns (bool) {
        emit SetTokenConverter(tokenConverter, _tokenConverter);
        tokenConverter = _tokenConverter;
        return true;
    }

    /**
        @notice Request a loan and attachs a mortgage request

        @dev Requires the loan signed by the borrower

        @param loanParams   0 - Ammount
                            1 - Interest rate
                            2 - Interest rate punitory
                            3 - Dues in
                            4 - Cancelable at
                            5 - Expiration of request
        @param metadata Loan metadata
        @param landId Land to buy with the mortgage
        @param v Loan signature by the borrower
        @param r Loan signature by the borrower
        @param s Loan signature by the borrower

        @return The id of the mortgage
    */
    function requestMortgage(
        uint256[6] loanParams,
        string metadata,
        uint256 landId,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256) {
        // Create a loan with the loanParams and metadata
        uint256 loanId = createLoan(loanParams, metadata);

        // Load NanoLoanEngine address
        NanoLoanEngine _nanoLoanEngine = nanoLoanEngine;

        // Approve the created loan with the provided signature
        require(_nanoLoanEngine.registerApprove(_nanoLoanEngine.getIdentifier(loanId), v, r, s), "Signature not valid");

        // Calculate the requested amount for the mortgage deposit
        uint256 landCost;
        (, , landCost, ) = landMarket.auctionByAssetId(landId);
        uint256 requiredDeposit = ((landCost * requiredTotal) / 100) - _nanoLoanEngine.getAmount(loanId);
        
        // Pull the required deposit amount
        Token _mana = mana;
        _tokenTransferFrom(_mana, msg.sender, this, requiredDeposit);
        require(_mana.approve(mortgageManager, requiredDeposit), "Error approve MANA transfer");

        // Create the mortgage request
        uint256 mortgageId = mortgageManager.requestMortgageId(Engine(_nanoLoanEngine), loanId, requiredDeposit, landId, tokenConverter);
        require(_mana.approve(mortgageManager, 0), "Error remove approve MANA transfer");

        emit NewMortgage(msg.sender, loanId, landId, mortgageId);
        
        return mortgageId;
    }

    /**
        @notice Pays a loan using mana

        @dev The amount to pay must be set on mana

        @param engine RCN Engine
        @param loan Loan id to pay
        @param amount Amount in MANA to pay

        @return True if the payment was performed
    */
    function pay(address engine, uint256 loan, uint256 amount) external returns (bool) {
        emit PaidLoan(engine, loan, amount);

        bytes32[4] memory loanParams = [
            bytes32(engine),
            bytes32(loan),
            bytes32(amount),
            bytes32(msg.sender)
        ];

        uint256[3] memory converterParams = [
            marginSpend,
            amount.safeMult(uint256(100000).safeAdd(maxSpend)) / 100000,
            rebuyThreshold
        ];

        require(address(converterRamp).delegatecall(
            bytes4(0x86ee863d),
            address(tokenConverter),
            address(mana),
            loanParams,
            0x140,
            converterParams,
            0x0
        ), "Error delegate pay call");
    }

    function _tokenTransferFrom(Token token, address from, address to, uint256 amount) internal {
        require(token.balanceOf(from) >= amount, "From balance is not enough");
        require(token.allowance(from, address(this)) >= amount, "Allowance is not enough");
        require(token.transferFrom(from, to, amount), "Transfer failed");
    }
}