pragma solidity ^0.5.0;
//activate certain feature of solidity
pragma experimental ABIEncoderV2;
//inherit from these contracts
import "@studydefi/money-legos/dydx/contracts/DydxFlashloanBase.sol";
import "@studydefi/money-legos/dydx/contracts/ICallee.sol";
//used to interact with erc20 token, open zeplin is a library which is internally used by studydefi
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract Flashloan1 is ICallee, DydxFlashloanBase {
    enum Direction { KyberToUniswap, UniswapToKyber } //enum is like an option which can have different value
    struct ArbInfo {
        Direction direction;
        uint repayAmount;
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
