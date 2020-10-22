// SPDX-License-Identifier: No License (None)
pragma solidity ^0.6.9;

import "./SafeMath.sol";
import "./Ownable.sol";
import "./TransferHelper.sol";

// TODO: Decimals correction
// TODO: balance + 1, to avoid Zero balance

interface ISwapFactory {
    function newFactory() external view returns(address);
    function validator() external view returns(address);
}

contract SwapPair {
    using SafeMath for uint256;

    //uint256 constant chain = 97;  // ETH mainnet = 1, Ropsten = 2, BSC_TESTNET = 97, BSC_MAINNET = 56
    uint256 constant MAX_AMOUNT = 2**192;
    uint256 constant NOMINATOR = 10**9;     // rate nominator
    address constant NATIVE = address(-1);  // address which holds native token ballance that was spent
    address constant FOREIGN = address(-2); // address which holds foreign token encoded ballance that was spent
    address constant NATIVE_COINS = 0x0000000000000000000000000000000000000009; // 0 - BNB, 1 - ETH, 2 - BTC


    address public token;               // token address
    address public tokenForeign;        // Foreign token address
    address public foreignSwapPair;     // foreign SwapPair contract address (on other blockchain)
    address public factory;             // factory address
    uint8 public decimals;
    uint8 public decimalsForeign;
    uint256 public totalSupply;

    // balanceOf contain two types of balance:
    // 1. balanceOf[user] - balance of tokens on native chain
    // 2. balanceOf[user+1] - swapped balance of foreign tokens. I.e. on BSC chain it contain amount of ETH that was swapped.  
    mapping (address => uint256) public balanceOf;
    //mapping (address => uint256) public cancelAmount;
    //mapping (address => uint256) public swapAmount;

    event CancelRequest(address indexed user, address token, uint256 amount);
    event CancelApprove(address indexed user, address token, uint256 amount);
    event ClaimRequest(address indexed user, address foreignToken, uint256 foreignAmount);
    event ClaimApprove(address indexed user, address foreignToken, uint256 foreignAmount, address token, uint256 amount);

    modifier onlyFactory() {
        require(msg.sender == factory, "Caller is not the factory");
        _;
    }

    constructor() public {
        factory = msg.sender;
    }

    function initialize(address _foreignPair, address tokenA, uint8 decimalsA, address tokenB, uint8 decimalsB) public onlyFactory {
        foreignSwapPair = _foreignPair;
        token = tokenA;
        tokenForeign = tokenB;
        decimals = decimalsA;
        decimalsForeign = decimalsB;
    }

    function update() public returns(bool) {
        factory = ISwapFactory(factory).newFactory();
        return true;
    }

    // encode 64 bits of rate (decimal = 9). and 192 bits of amount 
    // into uint256 where high 64 bits is rate and low 192 bit is amount
    // rate = foreign token price / native token price
    function _encode(uint256 rate, uint256 amount) internal pure returns(uint256 encodedBalance) {
        require(amount < MAX_AMOUNT, "Amount overflow");
        require(rate < 2**64, "Rate overflow");
        encodedBalance = rate * MAX_AMOUNT + amount;
    }

    // decode from uint256 where high 64 bits is rate and low 192 bit is amount
    // rate = foreign token price / native token price
    function _decode(uint256 encodedBalance) internal pure returns(uint256 rate, uint256 amount) {
        rate = encodedBalance / MAX_AMOUNT;
        amount = uint192(encodedBalance);
    }

    // swapAddress = user address + 1.
    // balanceOf contain two types of balance:
    // 1. balanceOf[user] - balance of tokens on native chain
    // 2. balanceOf[user+1] - swapped balance of foreign tokens. I.e. on BSC chain it contain amount of ETH that was swapped.
    function _swapAddress(address user) internal pure returns(address swapAddress) {
        swapAddress = address(uint160(user)+1);
    }

    // call appropriate transfer function
    function _transfer(address to, uint value) internal {
        if (token < NATIVE_COINS) 
            TransferHelper.safeTransferETH(to, value);
        else
            TransferHelper.safeTransfer(token, to, value);
    }

    // user's deposit to the pool, waiting for swap
    function deposit(address user, uint256 amount) external onlyFactory returns(bool) {
        balanceOf[user] = balanceOf[user].add(amount);
        totalSupply = totalSupply.add(amount);
        return true;
    }

    // cancel swap order request
    function cancel(address user, uint256 amount) external onlyFactory returns(bool) {
        balanceOf[user] = balanceOf[user].sub(amount,"Not enough tokens on the balance");
        totalSupply = totalSupply.sub(amount,"Not enough Total Supply");
        return true;
    }
    // approve cancel swap order and withdraw token from pool or discard cancel request
    function cancelApprove(address user, uint256 amount, bool approve) external onlyFactory returns(address, address) {
        if (approve) {    //approve cancel
            _transfer(user, amount);
        }
        else {  // discard cancel request.
            balanceOf[user] = balanceOf[user].add(amount);
            totalSupply = totalSupply.add(amount);
        }
        return (token, tokenForeign);
    }
    
    // request to claim token after swap
    function claim(address user, uint256 amount) external onlyFactory returns(bool) {
        address userSwap = _swapAddress(user);
        balanceOf[userSwap] = balanceOf[userSwap].add(amount);
        return true;
    }

    // approve / discard claim request
    function claimApprove(
            address user,
            uint256 amount, // foreign token amount to swap
            uint256 nativeEncoded,
            uint256 foreignSpent,
            uint256 rate,
            bool approve
        ) external onlyFactory returns(address, address, uint256 nativeAmount, uint256 rest) {
        address userSwap = _swapAddress(user);
        if(approve) { // approve claim
            (nativeAmount, rest) = calculateAmount(amount,nativeEncoded,foreignSpent,rate);
            if (rest != 0) {
                balanceOf[userSwap] = balanceOf[userSwap].sub(rest);    // not all amount swapped
            }
            totalSupply = totalSupply.sub(nativeAmount,"Not enough Total Supply");
            _transfer(user, nativeAmount);
        }
        else {  // discard claim
            balanceOf[userSwap] = balanceOf[userSwap].sub(amount);
        }
        return (token, tokenForeign, nativeAmount, rest);
    }

    function calculateAmount(
        uint256 foreignAmount,
        uint256 nativeEncoded,
        uint256 foreignSpent,
        uint256 rate    // Foreign token price / Native token price
    ) internal returns(uint256 nativeAmount, uint256 rest) {
        // step 1. Check is it enough unspent native tokens
        {
            (uint256 rate1, uint256 amount1) = _decode(nativeEncoded);
            amount1 = amount1.sub(balanceOf[NATIVE], "NativeSpent balance higher then remote");
            // rate1, amount1 - rate and amount ready to spend native tokens
            if (amount1 != 0) {
                uint256 requireAmount = foreignAmount.mul(NOMINATOR).div(rate1);
                if (requireAmount <= amount1) {
                    nativeAmount = requireAmount;
                    foreignAmount = 0;
                }
                else {
                    nativeAmount = amount1;
                    foreignAmount = (requireAmount - amount1).mul(rate1) / NOMINATOR;
                }
                balanceOf[NATIVE] = balanceOf[NATIVE].add(nativeAmount);
            }
        }
        require(totalSupply >= nativeAmount,"ERR: Not enough Total Supply");
        // step 2. recalculate rate for swapped tokens
        if (foreignAmount != 0) {
            uint256 requireAmount = foreignAmount.mul(rate) / NOMINATOR;
            if (totalSupply < nativeAmount.add(requireAmount)) {
                requireAmount = totalSupply.sub(nativeAmount);
                rest = foreignAmount.sub(requireAmount.mul(NOMINATOR).div(rate));
                foreignAmount = foreignAmount.sub(rest);
            }
            nativeAmount = nativeAmount.add(requireAmount);

            (uint256 rate2, uint256 amount) = _decode(balanceOf[FOREIGN]);
            uint256 amount2 = amount.sub(foreignSpent, "ForeignSpent balance higher then local");
            // rate2, amount2 - rate and amount swapped foreign tokens

            if (amount2 != 0) { // recalculate avarage rate 
                rate =  ((amount2.mul(rate2)/NOMINATOR).add(requireAmount)).mul(NOMINATOR).div(amount2.add(foreignAmount));
            }
            balanceOf[FOREIGN] = _encode(rate, amount.add(foreignAmount));
        }
    }

    receive() external payable {}
}
