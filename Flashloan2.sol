pragma solidity ^0.5.0;
//activate certain feature of solidity
pragma experimental ABIEncoderV2;
/* our flashloan contract will interact with couple of other smart contracts,likef kyber,
uniswap, wrapped ether and dai.
in this lesson we import the addresses of these contracts and create solidity pointers in order to
interact with them, we also need their interfaces to interact with them.
*/

//inherit from these contracts
import "@studydefi/money-legos/dydx/contracts/DydxFlashloanBase.sol";
import "@studydefi/money-legos/dydx/contracts/ICallee.sol";
//used to interact with erc20 token, open zeplin is a library which is internally used by studydefi
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

//we import interfaces of uniswap and wrapped ether
import "./IUniswapV2Router02.sol";
import "./IWeth.sol";
//we also need the interace of kyber, which is provided by money-leogs package,
// so we rename it to IKyberNetworkProxy to make is conistent with other interfaces
import { KyberNetworkProxy as IKyberNetworkProxy } from "@studydefi/money-legos/kyber/contracts/KyberNetworkProxy.sol";

contract Flashloan2 is ICallee, DydxFlashloanBase {
    enum Direction { KyberToUniswap, UniswapToKyber } //enum is like an option which can have different value
    struct ArbInfo {
        Direction direction;
        uint repayAmount;
    }

    IKyberNetworkProxy kyber; //pointers or variable to kyber contract interface that have imported
    IUniswapV2Router02 uniswap;  //pointers or variable to uniswap contract interface that have imported
    IWeth weth;  //pointers or variable to IWeth contract interface that have imported
    IERC20 dai;  //pointers or variable to IERC20 contract interface that have imported

    address constant KYBER_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; //A constant, which stores the address of ether on kyber
    //now we need to initialize the above pointers since if we dont they dont know the addresses
    //for this we use a constructor, so constructor is a func which is called when contract is deployed to the blockchain. its like __init__ func in python
    constructor(
        address kyberAddress,
        address uniswapAddress,
        address wethAddress,
        address daiAddress
    ) public {
    //here we instantiate all of the above pointers.
      kyber = IKyberNetworkProxy(kyberAddress); //passing the kyberAddress we got as argument to the IKyberNetworkProxy pointer and assigning to kyber
      uniswap = IUniswapV2Router02(uniswapAddress);
      weth = IWeth(wethAddress);
      dai = IERC20(daiAddress);
    }



    // This is the function that will be called postLoan
    // i.e. Encode the logic to handle your flashloaned funds here
    //callfunc is called once we have withdrawn money from dydx, here we do the arbitrage
    function callFunction(
        address sender,
        Account.Info memory account,
        bytes memory data //in data param we receive arbinfo struct since we need to decode it, so bytes type makes is more flexible
    ) public {
        ArbInfo memory arbInfo = abi.decode(data, (ArbInfo));
        uint256 balanceDai = dai.balanceOf(address(this)); //here we make a check to maker sure our dai balance is enough for the repay amount


        require(
            balanceDai >= arbInfo.repayAmount,
            "Not enough funds to repay dydx loan!");
    
    }

    function initiateFlashloan(
      address _solo, //address of dydx
      address _token, //address of token we borrow
      uint256 _amount, //amount that we borrow
      Direction _direction) 
        external 
    {
        ISoloMargin solo = ISoloMargin(_solo); //a pointer to smart contract of dydx

        // Get marketId from token address, market id of the token we borrow
        uint256 marketId = _getMarketIdFromTokenAddress(_solo, _token);

        // Calculate repay amount (_amount + (2 wei))
        // Approve transfer from, this is an amount we need to pay, borrowed amount+ 2 wei, 2 wei is fee
        uint256 repayAmount = _getRepaymentAmountInternal(_amount);
        IERC20(_token).approve(_solo, repayAmount);

        // 1. Withdraw $
        // 2. Call callFunction(...)
        // 3. Deposit back $
        Actions.ActionArgs[] memory operations = new Actions.ActionArgs[](3); //array of operations for the three actions we need

        operations[0] = _getWithdrawAction(marketId, _amount); //its when we borrow token from dydx
        operations[1] = _getCallAction( //its where we gonna have our arbitrage logic, 
            // Encode MyCustomData for callFunction
            abi.encode(ArbInfo({direction: _direction, repayAmount: repayAmount}))
        );
        operations[2] = _getDepositAction(marketId, repayAmount); //when we pay back the flashloan to dydx

        Account.Info[] memory accountInfos = new Account.Info[](1);
        accountInfos[0] = _getAccountInfo();

        solo.operate(accountInfos, operations);
    }
}
