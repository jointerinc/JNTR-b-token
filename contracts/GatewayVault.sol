// SPDX-License-Identifier: No License (None)
pragma solidity ^0.6.9;

import "./Ownable.sol";
import "./EnumerableSet.sol";

interface IBEP20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract GatewayVault is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet gateways;
    IBEP20 public token;    // JNTR token contract

    event AddGateway(address gateway);
    event RemoveGateway(address gateway);

    /**
     * @dev Throws if called by any account other than the Gateway.
     */
    modifier onlyGateway() {
        require(gateways.contains(msg.sender),"Not Gateway");
        _;
    }

    constructor (address _token) public {
        token = IBEP20(_token);
    }

    function addGateway(address gateway) external onlyOwner returns(bool) {
        gateways.add(gateway);
        emit AddGateway(gateway);
        return true;
    }

    function removeGateway(address gateway) external onlyOwner returns(bool) {
        gateways.remove(gateway);
        emit RemoveGateway(gateway);
        return true;
    }

    function vaultTransfer(address recipient, uint256 amount) external onlyGateway returns (bool) {
        token.transfer(recipient, amount);
        return true;
    }

    function vaultApprove(address spender, uint256 amount) external onlyGateway returns (bool) {
        token.approve(spender, amount);
        return true;
    }
}