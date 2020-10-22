// SPDX-License-Identifier: No License (None)
pragma solidity ^0.6.9;

import "./Ownable.sol";

interface IBEP20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
    function burnFrom(address account, uint256 amount) external returns(bool);
    function airdrop(address[] calldata recipients, uint256 amount) external returns(bool);
}

contract Airdrop is Ownable {
    uint256 public dropAmount = 100 ether; // tokens amount
    address public signer;
    mapping (address => mapping(address => bool)) isReceived; // token => user => isReceived
    event SetSigner(address signer);
    event SetDropAmount(uint256 dropAmount);

    function setSigner(address _address) external onlyOwner returns(bool) {
        signer = _address;
        emit SetSigner(_address);
        return true;
    }

    function setDropAmount(uint256 _dropAmount) external onlyOwner returns(bool) {
        dropAmount = _dropAmount;
        emit SetDropAmount(_dropAmount);
        return true;
    }    

    function faucet(address token, bytes32 r, bytes32 s, uint8 v) external returns(bool){
        require(signer == ecrecover(keccak256(abi.encodePacked(token, msg.sender, dropAmount)), v, r, s), "ECDSA signature is not valid.");
        require(!isReceived[token][msg.sender], "Tokens already received");
        isReceived[token][msg.sender] == true;
        address[] memory recipients = new address[](1);
        recipients[0] = msg.sender;
        IBEP20(token).airdrop(recipients, dropAmount);
        return true;
    }

    function airdrop(address token, uint256 amount, address[] calldata recipients) external onlyOwner returns(bool) {
            IBEP20(token).airdrop(recipients, amount);
        return true;
    }

    function airdrop2(address token, uint256[] calldata amounts, address[] calldata recipients) external onlyOwner returns(bool) {
        require(amounts.length == recipients.length);
        for (uint i = 0; i < recipients.length; i++) {
            IBEP20(token).transfer(recipients[i], amounts[i]);
        }
        return true;
    }
}