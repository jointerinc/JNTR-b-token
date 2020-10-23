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
    uint256 constant INVESTMENT_FLAG = 2**224;

    mapping(address => mapping(address => address payable)) public getPair;
    mapping(address => address) public foreignPair;
    address[] public allPairs;
    address public foreignFactory;

    mapping(address => mapping(address => uint256)) public cancelAmount;    // pair => user => cancelAmount
    mapping(address => mapping(address => uint256)) public swapAmount;    // pair => user => swapAmount

    uint256 public fee;
    address payable public validator;
    address public system;  // system address mey change fee amount
    address public auction; // auction address
    

    address public newFactory;            // new factory address to upgrade
    event PairCreated(address indexed tokenA, address indexed tokenB, address pair, uint);
    event SwapRequest(address indexed tokenA, address indexed tokenB, address indexed user, uint256 amountA, bool isInvestment);
    event CancelRequest(address indexed tokenA, address indexed tokenB, address indexed user, uint256 amountA, bool isInvestment);
    event CancelApprove(address indexed tokenA, address indexed tokenB, address indexed user, uint256 amountA, bool isInvestment);
    event ClaimRequest(address indexed tokenA, address indexed tokenB, address indexed user, uint256 amountB, bool isInvestment);
    event ClaimApprove(address indexed tokenA, address indexed tokenB, address indexed user, uint256 amountB, uint256 amountA, bool isInvestment);

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

    function setAuction(address _addr) external onlyOwner returns(bool) {
        auction = _addr;
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
                hex'93cdfaff21ec670a1ecae824881b508d73c4aaaf0d2be40fd90d52adcef8cc96' // init code hash
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

    // ================== on Ethereum network only =========================================================================

    //user should approve tokens transfer before calling this function.
    function swapInvestment(address tokenA, uint256 amount) external payable returns (bool) {
        address tokenB = address(0);    // BNB (native coin)
        return _swap(tokenA, tokenB, amount, true);
    }

    function cancelInvestment(address tokenA, uint256 amount) external payable returns (bool) {
        address tokenB = address(0);    // BNB (native coin)
        return _cancel(tokenA, tokenB, amount, true);
    }

    // ================= end Ethereum part =================================================================================

    // ====================== on BSC side only =============================================================================

    // tokenB - foreign token address or address(1) for ETH
    // amountB - amount of foreign tokens or ETH
    function claimInvestmentBehalf(address tokenB, address user, uint256 amountB) external onlySystem returns (bool) {
        address tokenA = address(0);    // BNB (native coin)
        return _claimTokenBehalf(tokenA, tokenB, user, amountB, true);
    }
    // ====================== end BSC part =================================================================================

    
    //user should approve tokens transfer before calling this function.
    function swap(address tokenA, address tokenB, uint256 amount) external payable returns (bool) {
        return _swap(tokenA, tokenB, amount, false);
    }

    function cancel(address tokenA, address tokenB, uint256 amount) external payable returns (bool) {
        return _cancel(tokenA, tokenB, amount, false);
    }
    function claimTokenBehalf(address tokenA, address tokenB, address user, uint256 amountB) external onlySystem returns (bool) {
        return _claimTokenBehalf(tokenA, tokenB, user, amountB, false);
    }

    //user should approve tokens transfer before calling this function.
    function _swap(address tokenA, address tokenB, uint256 amount, bool isInvestment) internal returns (bool) {
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
        SwapPair(pair).deposit(msg.sender, amount, isInvestment);
        emit SwapRequest(tokenA, tokenB, msg.sender, amount, isInvestment);
        return true;
    }

    function _cancel(address tokenA, address tokenB, uint256 amount, bool isInvestment) internal returns (bool) {
        require(msg.value >= IValidator(validator).getOracleFee(1), "Insufficient fee");    // check oracle fee for Cancel request
        require(amount != 0, "Zero amount");
        address payable pair = getPair[tokenA][tokenB];
        require(pair != address(0), 'PAIR_NOT_EXISTS');
        if (cancelAmount[pair][msg.sender] == 0) {  // new cancel request
            cancelAmount[pair][msg.sender] = amount;
            SwapPair(pair).cancel(msg.sender, amount, isInvestment);
        }
        else { // repeat cancel request in case oracle issues.
            amount = cancelAmount[pair][msg.sender];
        }

        // transfer fee to validator. May be changed to request tokens for compensation
        validator.transfer(msg.value);

        if (isInvestment)
            IValidator(validator).checkBalance(pair, foreignPair[pair], _investAddress(msg.sender));    // on Ethereum network only
        else
            IValidator(validator).checkBalance(pair, foreignPair[pair], _swapAddress(msg.sender));
        emit CancelRequest(tokenA, tokenB, msg.sender, amount, isInvestment);
        return true;
    }


    // amountB - amount of foreign token to swap
    function _claimTokenBehalf(address tokenA, address tokenB, address user, uint256 amountB, bool isInvestment) internal returns (bool) {
        address payable pair = getPair[tokenA][tokenB];
        require(pair != address(0), 'PAIR_NOT_EXISTS');
        require(amountB != 0, "Zero amount");
        if (swapAmount[pair][user] == 0) {  // new cancel request
            swapAmount[pair][user] = amountB;
            SwapPair(pair).claim(user, amountB, isInvestment);
        }
        else { // repeat cancel request in case oracle issues.
            amountB = swapAmount[pair][user];
        }
        if (isInvestment)
            IValidator(validator).checkBalance(pair, foreignPair[pair], _investAddress(msg.sender));    // on BSC network only
        else
            IValidator(validator).checkBalances(pair, foreignPair[pair], user);
        emit ClaimRequest(tokenA, tokenB, user, amountB, isInvestment);
        return true;
    }

    // On both side (BEP and ERC) we accumulate user's deposits (balance).
    // If balance on one side it greater then on other, the difference means user deposit.
    function balanceCallback(address payable pair, address user, uint256 balanceForeign) external returns(bool) {
        require (validator == msg.sender, "Not validator");
        (uint256 balance, bool isInvestment) = _getBalance(SwapPair(pair).balanceOf(user));
        if (isInvestment) user = _swapAddress(user);    // real user address = investAddress + 1
        uint256 amount = cancelAmount[pair][user];
        require (amount != 0, "No active cancel request");
        cancelAmount[pair][user] = 0;
        address tokenA;
        address tokenB;
        bool isApproved = (balanceForeign <= balance);
        (tokenA, tokenB) = SwapPair(pair).cancelApprove(user, amount, isApproved, isInvestment);
        if(!isApproved) amount = 0;

        emit CancelApprove(tokenA, tokenB, user, amount, isInvestment);
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
        (uint256 balance, bool isInvestment) = _getBalance(balanceForeign);
        address userSwap;
        if (isInvestment) {
            userSwap = user;    // investAddress
            user = _swapAddress(user);    // real user address = investAddress + 1
        }
        else {
            userSwap = _swapAddress(user);
        }

        uint256 amountB = swapAmount[pair][user];
        require (amountB != 0, "No active swap request");
        swapAmount[pair][user] = 0;
        address tokenA;
        address tokenB;
        uint256 nativeAmount;
        uint256 rest;
        if (balance >= SwapPair(pair).balanceOf(userSwap)) { // is approve claim
            (tokenA, tokenB, nativeAmount, rest) = SwapPair(pair).claimApprove(user, amountB, nativeEncoded, foreignSpent, rate, true, isInvestment);
            amountB = amountB.sub(rest);
        }
        else {
            (tokenA, tokenB, nativeAmount, rest) = SwapPair(pair).claimApprove(user, amountB, nativeEncoded, foreignSpent, rate, false, isInvestment);
            amountB = 0;
        }

        emit ClaimApprove(tokenA, tokenB, user, amountB, nativeAmount, isInvestment);
        return true;
    }

    // swapAddress = user address + 1.
    // balanceOf contain two types of balance:
    // 1. balanceOf[user] - balance of tokens on native chain
    // 2. balanceOf[user+1] - swapped balance of foreign tokens. I.e. on BSC chain it contain amount of ETH that was swapped.
    function _swapAddress(address user) internal pure returns(address swapAddress) {
        swapAddress = address(uint160(user)+1);
    }
    // 3. balanceOf[user-1] - investment to auction total balance.
    function _investAddress(address user) internal pure returns(address investAddress) {
        investAddress = address(uint160(user)-1);
    }
    // return balance and investment flag
    function _getBalance(uint256 balanceWithFlag) internal pure returns(uint256 balance, bool isInvestment) {
        if(INVESTMENT_FLAG & balanceWithFlag != 0) {
            balance = uint192(balanceWithFlag);
            isInvestment = true;
        }
        else {
            balance = balanceWithFlag;
            isInvestment = false;
        }
    }
}