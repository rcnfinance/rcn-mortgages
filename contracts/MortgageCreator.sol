pragma solidity ^0.4.19;

import "./interfaces/Token.sol";
import "./interfaces/TokenConverter.sol";
import "./MortgageManager.sol";
import "./ERC721Base.sol";

interface NanoLoanEngine {
    function createLoan(address _oracleContract, address _borrower, bytes32 _currency, uint256 _amount, uint256 _interestRate,
        uint256 _interestRatePunitory, uint256 _duesIn, uint256 _cancelableAt, uint256 _expirationRequest, string _metadata) public returns (uint256);
    function getIdentifier(uint256 index) public view returns (bytes32);
    function registerApprove(bytes32 identifier, uint8 v, bytes32 r, bytes32 s) public returns (bool);
    function getAmount(uint256 index) public view returns (uint256);
}

contract MortgageCreator {
    MortgageManager public mortgageManager;
    NanoLoanEngine public nanoLoanEngine;
    Token public rcn;
    Token public mana;
    LandMarket public landMarket;
    TokenConverter public tokenConverter;

    address public manaOracle;
    uint256 public requiredTotal = 110;

    bytes32 public constant MANA_CURRENCY = 0x4d414e4100000000000000000000000000000000000000000000000000000000;

    event NewMortgage(address borrower, uint256 loanId, uint256 landId, uint256 mortgageId);

    function MortgageCreator(
        MortgageManager _mortgageManager,
        NanoLoanEngine _nanoLoanEngine,
        Token _rcn,
        Token _mana,
        LandMarket _landMarket,
        address _manaOracle,
        TokenConverter _tokenConverter
    ) public {
        mortgageManager = _mortgageManager;
        nanoLoanEngine = _nanoLoanEngine;
        rcn = _rcn;
        mana = _mana;
        landMarket = _landMarket;
        manaOracle = _manaOracle;
        tokenConverter = _tokenConverter;
    }

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

    function requestMortgage(uint256[6] memory loanParams, string metadata, uint256 landId, uint8 v, bytes32 r, bytes32 s) public returns (uint256) {
        uint256 loanId = createLoan(loanParams, metadata);
        require(nanoLoanEngine.registerApprove(nanoLoanEngine.getIdentifier(loanId), v, r, s));

        uint256 landCost;
        (, , landCost, ) = landMarket.auctionByAssetId(landId);

        uint256 requiredDeposit = ((landCost * requiredTotal) / 100) - nanoLoanEngine.getAmount(loanId);
        
        require(mana.transferFrom(msg.sender, this, requiredDeposit));
        require(mana.approve(mortgageManager, requiredDeposit));

        uint256 mortgageId = mortgageManager.requestMortgageId(Engine(nanoLoanEngine), loanId, requiredDeposit, landId, tokenConverter);
        NewMortgage(msg.sender, loanId, landId, mortgageId);
        
        return mortgageId;
    }
}