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
// so we rename it to IKyberNetworkProxy to make it conistent with other interfaces
import { KyberNetworkProxy as IKyberNetworkProxy } from "@studydefi/money-legos/kyber/contracts/KyberNetworkProxy.sol";

contract Flashloan3 is ICallee, DydxFlashloanBase {
    enum Direction { KyberToUniswap, UniswapToKyber } //enum is like an option which can have different value
    struct ArbInfo {
        Direction direction;
        uint repayAmount;
    }

    event NewArbitrage (
      Direction direction, //direction
      uint profit, //profit
      uint date //date
    );

    IKyberNetworkProxy kyber; //pointers or variable to kyber contract interface that have imported
    IUniswapV2Router02 uniswap;  //pointers or variable to uniswap contract interface that have imported
    IWeth weth;  //pointers or variable to IWeth contract interface that have imported
    IERC20 dai;  //pointers or variable to IERC20 contract interface that have imported
    address beneficiary;
    address constant KYBER_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; //A constant, which stores the address of ether on kyber
    //now we need to initialize the above pointers since if we dont they dont know the addresses
    //for this we use a constructor, so constructor is a func which is called when contract is deployed to the blockchain. its like __init__ func in python
    constructor(
        address kyberAddress,
        address uniswapAddress,
        address wethAddress,
        address daiAddress,
        address beneficiaryAddress
    ) public {
    //here we instantiate all of the above pointers.
      kyber = IKyberNetworkProxy(kyberAddress); //passing the kyberAddress we got as argument to the IKyberNetworkProxy pointer and assigning to kyber
      uniswap = IUniswapV2Router02(uniswapAddress);
      weth = IWeth(wethAddress);
      dai = IERC20(daiAddress);
      beneficiary = beneficiaryAddress;
    }



    // This is the function that will be called postLoan
    // i.e. Encode the logic to handle your flashloaned funds here
    //callfunc is called once we have withdrawn money from dydx, here we do the arbitrage
    function callFunction(
        address sender,
        Account.Info memory account,
        bytes memory data //in data param we receive arbinfo struct since we need to decode it, so bytes type makes it more flexible
    ) public {
        ArbInfo memory arbInfo = abi.decode(data, (ArbInfo));
        uint256 balanceDai = dai.balanceOf(address(this)); //here we make a check to maker sure our dai balance is enough for the repay amount


        

        if(arbInfo.direction == Direction.KyberToUniswap) {
          //Buy ETH on Kyber
          dai.approve(address(kyber), balanceDai); // we approve dai to be spent by kyber
          (uint expectedRate, ) = kyber.getExpectedRate( //this expectedrate returns a tuple that we only get expectedrate and ignore others
            dai, //pointe to the token we provide as input
            IERC20(KYBER_ETH_ADDRESS), //pointer to the output token which ether, this address we get from constant is only used on kyber
            balanceDai //amount of dai that we gonna trade
          );
          kyber.swapTokenToEther(dai, balanceDai, expectedRate); //now we can trade, dai with balance and with this rate

          //Sell ETH on Uniswap
          address[] memory path = new address[](2); //here we create a path for the tokes we trade, its a memory array of lenght 2
          path[0] = address(weth); //first element is wrapped ether
          path[1] = address(dai); //second element
          uint[] memory minOuts = uniswap.getAmountsOut(address(this).balance, path); //getting the price of dai, input the balance of smart contract, it returns an array of integer
          uniswap.swapExactETHForTokens.value(address(this).balance)( //calling functions of uniswap to do the trade,send this amount of ether to the smart contract
            minOuts[1], //minimum price that we want
            path, //path
            address(this), //address of this contract
            now //deadline, its useful when you send a transaction from outside a contract since there will be slippage
          );
        }
        //now we do the inverse of the above trade
         else {
          //Buy ETH on Uniswap
          dai.approve(address(uniswap), balanceDai); 
          address[] memory path = new address[](2);
          path[0] = address(dai);
          path[1] = address(weth);
          uint[] memory minOuts = uniswap.getAmountsOut(balanceDai, path); 
          uniswap.swapExactTokensForETH(
            balanceDai, 
            minOuts[1], 
            path, 
            address(this), 
            now
          );

          //Sell ETH on Kyber
          (uint expectedRate, ) = kyber.getExpectedRate(
            IERC20(KYBER_ETH_ADDRESS), //from ether
            dai, //to dai
            address(this).balance //amount of ether
          );
          kyber.swapEtherToToken.value(address(this).balance)(
            dai, 
            expectedRate
          );
        }

        require(
            dai.balanceOf(address(this)) >= arbInfo.repayAmount,
            "Not enough funds to repay dydx loan!"); //our dai balance should be bigger than repay amount
        
        //here we calculate our profit to withdraw, its gonna be difference between the dai balance of this contract and the repayamount
        
        uint profit = dai.balanceOf(address(this)) - arbInfo.repayAmount; 
        dai.transfer(beneficiary, profit); //send the benefit to the beneficiary address, 
        emit NewArbitrage(arbInfo.direction, profit, now); //emit an event to describe the arbitrage that just happnened
        //to the event we pass direction, profit and date. and we need to define it at the top too
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

    function() external payable {} //a fallback func without any name, if this fallback func does not exist the transfer of ether will fail
    //since when we do an eth transaction it means we do a fallback so if the fallback func does not exist the transfer would fail
}
