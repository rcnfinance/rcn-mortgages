pragma solidity ^0.4.24;

contract Ownable {
    address public owner;

    event SetOwner(address _owner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Sender not owner");
        _;
    }

    constructor() public {
        owner = msg.sender;
        emit SetOwner(msg.sender);
    }

    /**
        @dev Transfers the ownership of the contract.

        @param _to Address of the new owner
    */
    function setOwner(address _to) external onlyOwner returns (bool) {
        require(_to != address(0), "Owner can't be 0x0");
        owner = _to;
        emit SetOwner(_to);
        return true;
    } 
} 