pragma solidity ^0.4.19;

import "./Token.sol";
import "./Oracle.sol";

interface NanoLoanEngine {
    function pay(uint index, uint256 _amount, address _from, bytes oracleData) public returns (bool);
    function rcn() public view returns (Token);
    function getOracle(uint256 index) public view returns (Oracle);
    function getAmount(uint256 index) public view returns (uint256);
}