pragma solidity ^0.4.19;

import "./interfaces/Oracle.sol";
import "./interfaces/Token.sol";
import "./utils/Ownable.sol";

contract BancorConvertor {
    function getReturn(address _fromToken, address _toToken, uint256 _amount) public view returns (uint256);
}

contract BancorOracle is Oracle {
    address public rcn;
    Oracle public delegate;
    
    event SetSource(bytes32 currency, address toToken, address convertor);

    struct BancorConvertion {
        address toToken;
        address convertor;
    }

    mapping(bytes32 => BancorConvertion) public tickerSource;

    function setRcn(address _rcn) public onlyOwner returns (bool) {
        rcn = _rcn;
        return true;
    }

    function setDelegate(Oracle _delegate) public onlyOwner returns (bool) {
        delegate = _delegate;
        return true;
    }

    function updateConvertion(string ticker, address toToken, address convertor) public returns (bool) {
        return updateConvertion(encodeCurrency(ticker), toToken, convertor);
    }

    function updateConvertion(bytes32 code, address toToken, address convertor) public onlyOwner returns (bool) {
        tickerSource[code] = BancorConvertion(toToken, convertor);
        SetSource(code, toToken, convertor);
        return true;
    }

    function addCurrencyConverter(string ticker, address toToken, address convertor) public onlyOwner returns (bool) {
        addCurrency(ticker);
        bytes32 code = encodeCurrency(ticker);
        tickerSource[code] = BancorConvertion(toToken, convertor);
        SetSource(code, toToken, convertor);
        return true;
    }

    function url() public view returns (string) {
        return "";
    }

    function getRate(bytes32 currency, bytes data) public returns (uint256 rate, uint256 decimals) {
        if (delegate != address(0)) {
            return delegate.getRate(currency, data);
        }

        BancorConvertion memory bConvertion = tickerSource[currency];
        decimals = 18;
        rate = BancorConvertor(bConvertion.convertor).getReturn(bConvertion.toToken, rcn, 1 ether);
    }
}