// SPDX-License-Identifier: No License (None)
pragma solidity ^0.6.9;

//https://api.bscscan.com/api?module=account&action=tokenbalance&contractaddress=0x78e1936f065Fd4082387622878C7d11c9f05ECF4&address=0x333AfaF781d196381fffA54e3ba53625eDADF0fc&tag=latest

import "./SafeMath.sol";
import "./Ownable.sol";

interface IBEP20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
    function burnFrom(address account, uint256 amount) external returns(bool);
}

interface IGatewayVault {
    function vaultTransfer(address recipient, uint256 amount) external returns (bool);
    function vaultApprove(address spender, uint256 amount) external returns (bool);
}

interface IGatewayB {
    function bToToken(uint256 amount) external returns (bool);
    function tokenToB(uint256 amount) external returns (bool);
}

interface IValidator {
    function checkBalance(uint256 network, address tokenForeign, address user) external returns(uint256);
}

contract GatewayBsc is Ownable {
    using SafeMath for uint256;

    uint256 public constant chain = 2;  // ETH mainnet = 1, Ropsten = 2, BSC_TESTNET = 97, BSC_MAINNET = 56

    IBEP20 public token;            // JNTR
    IBEP20 public token_b;          // JNTR/b
    address public gateway_b;       // swap gateway JNTR <> JNTR/b
    address public gatewayVault;    // holds JNTR tokens from different gateways
    address public foreignGateway;  // gateway contract address on foreign network
    string public name;

    address payable public validator;
    uint256 public fee;
    uint256 public claimFee;
    address public system;  // system address mey change fee amount

    mapping (address => uint256) public balanceOf;
    mapping (address => uint256) public balanceSwap;
    mapping (uint256 => uint256) public orders; // request ID => token (1 = JNTR, 2 = JNTR/b)

    event Swap(address indexed user, uint256 amount);
    event SwapB(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 amount, uint256 indexed tokenNative);

    constructor (
        address _token,     // JNTR token contract
        address _token_b,   // JNTR/b token contract
        address _gateway_b, // the gateway contract address JNTR <> JNTR/b
        address _gatewayVault,
        string memory _name,          // name of swap gateway
        address _system         // address of system with right to change fee
    ) public {
        token = IBEP20(_token);
        token_b = IBEP20(_token_b);
        gateway_b = _gateway_b;
        gatewayVault = _gatewayVault;
        name = _name;
        system = _system;
    }

    function setFee(uint256 _fee) external returns(bool) {
        require (system == msg.sender, "Not system");
        fee = _fee;
        return true;
    }

    function setClaimFee(uint256 _fee) external returns(bool) {
        require (system == msg.sender, "Not system");
        claimFee = _fee;
        return true;
    }

    function setForeignGateway(address _addr) external onlyOwner returns(bool) {
        foreignGateway = _addr;
        return true;
    }
    
    function setSystem(address _system) external onlyOwner returns(bool) {
        system = _system;
        return true;
    }

    function setValidator(address payable _validator) external onlyOwner returns(bool) {
        validator = _validator;
        return true;
    }

    //user should approve tokens transfer before calling this function. Swap JNTR to foreign token
    function swapToken(uint256 amount) external payable returns (bool) {
        require(msg.value >= fee,"Insufficient fee");
        token.transferFrom(msg.sender, gatewayVault, amount);
        balanceOf[msg.sender] = balanceOf[msg.sender].add(amount);
        validator.transfer(msg.value); // transfer fee to validator for Oracle payment
        emit Swap(msg.sender, amount);
    }

    //user should approve tokens transfer before calling this function. Swap JNTR/b to foreign token
    function swapTokenB(uint256 amount) external payable returns (bool) {
        require(msg.value >= fee,"Insufficient fee");
        // swap to JNTR at first
        token_b.transferFrom(msg.sender, address(this), amount);
        token_b.approve(gateway_b, amount);
        IGatewayB(gateway_b).bToToken(amount);
        // transfer JNTR to vault
        token.transfer(gatewayVault, amount);
        balanceOf[msg.sender] = balanceOf[msg.sender].add(amount);
        validator.transfer(msg.value); // transfer fee to validator for Oracle payment
        emit SwapB(msg.sender, amount);
    }

    function claimToken() external payable returns (bool) {
        require(msg.value >= claimFee,"Insufficient fee");
        validator.transfer(msg.value); // transfer fee to validator for Oracle payment
        uint256 id = IValidator(validator).checkBalance(chain, foreignGateway, msg.sender);
        orders[id] = 1; //JNTR
        return true;
    }

    function claimTokenB() external payable returns (bool) {
        require(msg.value >= claimFee,"Insufficient fee");
        validator.transfer(msg.value); // transfer fee to validator for Oracle payment
        uint256 id = IValidator(validator).checkBalance(chain, foreignGateway, msg.sender);
        orders[id] = 2; //JNTR/b
        return true;
    }

    function claimTokenBehalf(address user) external returns (bool) {
        uint256 id = IValidator(validator).checkBalance(chain, foreignGateway, user);
        orders[id] = 1; //JNTR
        return true;
    }

    function claimTokenBBehalf(address user) external returns (bool) {
        uint256 id = IValidator(validator).checkBalance(chain, foreignGateway, user);
        orders[id] = 2; //JNTR/b
        return true;
    }

    // On both side (BEP and ERC) we accumulate user's deposits (balance).
    // If balance on one side it greater then on other, the difference means user deposit.
    function validatorCallback(uint256 requestId, address tokenForeign, address user, uint256 balanceForeign) external returns(bool) {
        require (validator == msg.sender, "Not validator");
        uint256 nativeToken = orders[requestId];
        require (nativeToken != 0, "Wrong requestId");
        require (tokenForeign == foreignGateway, "Wrong foreign token");
        uint256 balance = balanceSwap[user];    // our records of user balance
        require(balanceForeign > balance, "No BEP20 tokens deposit");
        balanceSwap[user] = balanceForeign; // update balance
        uint256 amount = balanceForeign - balance;
        if (nativeToken == 1) {    // JNTR
            IGatewayVault(gatewayVault).vaultTransfer(user, amount);
        }
        else {    // JNTR/b 
            IGatewayVault(gatewayVault).vaultTransfer(address(this), amount);
            token.approve(gateway_b, amount);
            IGatewayB(gateway_b).tokenToB(amount);
            token_b.transfer(user, amount);
        }

        Claim(user, amount, nativeToken);
        return true;
    }
}