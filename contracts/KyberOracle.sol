pragma solidity ^0.4.19;

import "./interfaces/Oracle.sol";
import "./interfaces/Token.sol";
import "./utils/Ownable.sol";

contract KyberNetwork {
    function getExpectedRate(address src, address dest, uint srcQty)
        public view
        returns (uint expectedRate, uint slippageRate);
}

contract KyberOracle is Oracle {
    KyberNetwork public kyber;
    address public rcn;
    Oracle public delegate;
    
    mapping(bytes32 => address) public tickerToToken;
    mapping(bytes32 => uint256) public tickerToDecimals;

    function setRcn(address _rcn) public onlyOwner returns (bool) {
        rcn = _rcn;
        return true;
    }

    function setKyber(KyberNetwork _kyber) public onlyOwner returns (bool) {
        kyber = _kyber;
        return true;
    }

    function setDelegate(Oracle _delegate) public onlyOwner returns (bool) {
        delegate = _delegate;
        return true;
    }

    function changeToken(string ticker, address token) public returns (bool) {
        return changeToken(keccak256(ticker), token);
    }

    function changeToken(bytes32 _hash, address token) public onlyOwner returns (bool) {
        tickerToToken[_hash] = token;
        return true;
    }

    function changeDecimals(string ticker, uint256 decimals) public returns (bool) {
        return changeDecimals(keccak256(ticker), decimals);
    }

    function changeDecimals(bytes32 _hash, uint256 decimals) public onlyOwner returns (bool) {
        tickerToDecimals[_hash] = decimals;
        return true;
    }

    function addCurrency(string ticker, address token, uint256 decimals) public onlyOwner returns (bool) {
        addCurrency(ticker);
        bytes32 code = encodeCurrency(ticker);
        tickerToToken[code] = token;
        tickerToDecimals[code] = decimals;
        return true;
    }

    function url() public view returns (string) {
        return "";
    }

    function getRate(bytes32 currency, bytes data) public returns (uint256 rate, uint256 decimals) {
        if (delegate != address(0)) {
            return delegate.getRate(currency, data);
        }

        (rate, ) = kyber.getExpectedRate(tickerToToken[currency], rcn, 1 ether);
        decimals = tickerToDecimals[currency];
    }
}