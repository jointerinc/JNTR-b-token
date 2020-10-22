// SPDX-License-Identifier: No License (None)
pragma solidity ^0.6.9;

//mport "./SafeMath.sol";
//import "./Ownable.sol";
import "./SwapPair.sol";

// TODO: request prices for tokens (provide tokenA and tokenB)

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IValidator {
    // returns: user balance, native (foreign for us) encoded balance, foreign (native for us) encoded balance
    function checkBalances(address pair, address foreignSwapPair, address user) external returns(uint256);
    // returns: user balance
    function checkBalance(address pair, address foreignSwapPair, address user) external returns(uint256);
    // returns: oracle fee
    function getOracleFee(uint256 req) external returns(uint256);  //req: 1 - cancel, 2 - claim, returns: value
}


contract SwapFactory is Ownable {
    using SafeMath for uint256;

    address constant NATIVE_COINS = 0x0000000000000000000000000000000000000009; // 0 - BNB, 1 - ETH, 2 - BTC

    mapping(address => mapping(address => address payable)) public getPair;
    mapping(address => address) public foreignPair;
    address[] public allPairs;
    address public foreignFactory;

    mapping(address => mapping(address => uint256)) public cancelAmount;    // pair => user => cancelAmount
    mapping(address => mapping(address => uint256)) public swapAmount;    // pair => user => swapAmount

    uint256 public fee;
    address payable public validator;
    address public system;  // system address mey change fee amount
    

    address public newFactory;            // new factory address to upgrade
    event PairCreated(address indexed tokenA, address indexed tokenB, address pair, uint);
    event SwapRequest(address indexed tokenA, address indexed tokenB, address indexed user, uint256 amountA);
    event CancelRequest(address indexed tokenA, address indexed tokenB, address indexed user, uint256 amountA);
    event CancelApprove(address indexed tokenA, address indexed tokenB, address indexed user, uint256 amountA);
    event ClaimRequest(address indexed tokenA, address indexed tokenB, address indexed user, uint256 amountB);
    event ClaimApprove(address indexed tokenA, address indexed tokenB, address indexed user, uint256 amountB, uint256 amountA);

    /**
    * @dev Throws if called by any account other than the system.
    */
    modifier onlySystem() {
        require(msg.sender == system, "Caller is not the system");
        _;
    }

    constructor (address _system) public {
        system = _system;
        newFactory = address(this);
    }

    function setFee(uint256 _fee) external onlySystem returns(bool) {
        fee = _fee;
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

    function setForeignFactory(address _addr) external onlyOwner returns(bool) {
        foreignFactory = _addr;
        return true;
    }

    function setNewFactory(address _addr) external onlyOwner returns(bool) {
        newFactory = _addr;
        return true;
    }


    function createPair(address tokenA, uint8 decimalsA, address tokenB, uint8 decimalsB) public onlyOwner returns (address payable pair) {
        require(getPair[tokenA][tokenB] == address(0), 'PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(SwapPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(tokenA, tokenB));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        foreignPair[pair] = getForeignPair(tokenB, tokenA);
        SwapPair(pair).initialize(foreignPair[pair], tokenA, decimalsA, tokenB, decimalsB);
        getPair[tokenA][tokenB] = pair;

        allPairs.push(pair);
        emit PairCreated(tokenA, tokenB, pair, allPairs.length);
    }

    function getForeignPair(address tokenA, address tokenB) internal view returns(address pair) {
        pair = address(uint(keccak256(abi.encodePacked(
                hex'ff',
                foreignFactory,
                keccak256(abi.encodePacked(tokenA, tokenB)),
                hex'3722e4f39f573258986069edce289790407dd408aa60f7d416d6f8b5b6b3c653' // init code hash
            ))));
    }

    // set already existed pairs in case of contract upgrade
    function setPairs(address[] memory tokenA, address[] memory tokenB, address payable[] memory pair) external onlyOwner returns(bool) {
        uint256 len = tokenA.length;
        while (len > 0) {
            len--;
            getPair[tokenA[len]][tokenB[len]] = pair[len];
            foreignPair[pair[len]] = SwapPair(pair[len]).foreignSwapPair();
            allPairs.push(pair[len]);
            emit PairCreated(tokenA[len], tokenB[len], pair[len], allPairs.length);            
        }
        return true;
    }
    // calculates the CREATE2 address for a pair without making any external calls
    function pairAddressFor(address tokenA, address tokenB) external view returns (address pair, bytes32 bytecodeHash) {
        bytes memory bytecode = type(SwapPair).creationCode;
        bytecodeHash = keccak256(bytecode);
        pair = address(uint(keccak256(abi.encodePacked(
                hex'ff',
                address(this),
                keccak256(abi.encodePacked(tokenA, tokenB)),
                bytecodeHash    // hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f' // init code hash
            ))));
    }


    //user should approve tokens transfer before calling this function.
    function swap(address tokenA, address tokenB, uint256 amount) external payable returns (bool) {
        uint256 feeAmount = msg.value;
        if (tokenA < NATIVE_COINS) feeAmount = feeAmount.sub(amount);   // if native coin, then feeAmount = msg.value - swap amount
        require(feeAmount >= fee,"Insufficient fee");
        require(amount != 0, "Zero amount");
        address payable pair = getPair[tokenA][tokenB];
        require(pair != address(0), 'PAIR_NOT_EXISTS');
        
        // transfer fee to validator. May be changed to request tokens for compensation
        validator.transfer(feeAmount);

        if (tokenA < NATIVE_COINS)
            TransferHelper.safeTransferETH(pair, amount);
        else 
            TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amount);
        SwapPair(pair).deposit(msg.sender, amount);
        emit SwapRequest(tokenA, tokenB, msg.sender, amount);
        return true;
    }

    function cancel(address tokenA, address tokenB, uint256 amount) external payable returns (bool) {
        require(msg.value >= IValidator(validator).getOracleFee(1), "Insufficient fee");    // check oracle fee for Cancel request
        require(amount != 0, "Zero amount");
        address payable pair = getPair[tokenA][tokenB];
        require(pair != address(0), 'PAIR_NOT_EXISTS');
        if (cancelAmount[pair][msg.sender] == 0) {  // new cancel request
            cancelAmount[pair][msg.sender] = amount;
            SwapPair(pair).cancel(msg.sender, amount);
        }
        else { // repeat cancel request in case oracle issues.
            amount = cancelAmount[pair][msg.sender];
        }

        // transfer fee to validator. May be changed to request tokens for compensation
        validator.transfer(msg.value);

        IValidator(validator).checkBalance(pair, foreignPair[pair], _swapAddress(msg.sender));
        emit CancelRequest(tokenA, tokenB, msg.sender, amount);
        return true;
    }

    // amountB - amount of foreign token to swap
    function claimTokenBehalf(address tokenA, address tokenB, address user, uint256 amountB) external onlySystem returns (bool) {
        address payable pair = getPair[tokenA][tokenB];
        require(pair != address(0), 'PAIR_NOT_EXISTS');
        require(amountB != 0, "Zero amount");
        if (swapAmount[pair][user] == 0) {  // new cancel request
            swapAmount[pair][user] = amountB;
            SwapPair(pair).claim(user, amountB);
        }
        else { // repeat cancel request in case oracle issues.
            amountB = swapAmount[pair][user];
        }
        IValidator(validator).checkBalances(pair, foreignPair[pair], user);
        emit ClaimRequest(tokenA, tokenB, user, amountB);
        return true;
    }

    // On both side (BEP and ERC) we accumulate user's deposits (balance).
    // If balance on one side it greater then on other, the difference means user deposit.
    function balanceCallback(address payable pair, address user, uint256 balanceForeign) external returns(bool) {
        require (validator == msg.sender, "Not validator");
        uint256 amount = cancelAmount[pair][user];
        require (amount != 0, "No active cancel request");
        cancelAmount[pair][user] = 0;
        address tokenA;
        address tokenB;
        if (balanceForeign <= SwapPair(pair).balanceOf(user)) {    //approve cancel
            (tokenA, tokenB) = SwapPair(pair).cancelApprove(user, amount, true);
        }
        else {  // discard cancel
            (tokenA, tokenB) = SwapPair(pair).cancelApprove(user, amount, false);
            amount = 0;
        }
        emit CancelApprove(tokenA, tokenB, user, amount);
        return true;
    }

    function balancesCallback(
            address payable pair,
            address user,
            uint256 balanceForeign,
            uint256 nativeEncoded,
            uint256 foreignSpent,
            uint256 rate    // rate = foreignPrice.mul(NOMINATOR) / nativePrice;   // current rate
        ) external returns(bool) {
        require (validator == msg.sender, "Not validator");
        address userSwap = _swapAddress(user);
        uint256 amountB = swapAmount[pair][user];
        require (amountB != 0, "No active swap request");
        swapAmount[pair][user] = 0;
        address tokenA;
        address tokenB;
        uint256 nativeAmount;
        uint256 rest;
        if(balanceForeign >= SwapPair(pair).balanceOf(userSwap)) { // approve claim
            (tokenA, tokenB, nativeAmount, rest) = SwapPair(pair).claimApprove(user, amountB, nativeEncoded, foreignSpent, rate, true);
            amountB = amountB.sub(rest);
        }
        else {  // claim not approved
            (tokenA, tokenB, nativeAmount, rest) = SwapPair(pair).claimApprove(user, amountB, nativeEncoded, foreignSpent, rate, false);
            amountB = 0;
        }
        emit ClaimApprove(tokenA, tokenB, user, amountB, nativeAmount);
        return true;
    }

    // swapAddress = user address + 1.
    // balanceOf contain two types of balance:
    // 1. balanceOf[user] - balance of tokens on native chain
    // 2. balanceOf[user+1] - swapped balance of foreign tokens. I.e. on BSC chain it contain amount of ETH that was swapped.
    function _swapAddress(address user) internal pure returns(address swapAddress) {
        swapAddress = address(uint160(user)+1);
    }


}