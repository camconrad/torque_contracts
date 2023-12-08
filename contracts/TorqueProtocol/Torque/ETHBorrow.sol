// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

//  _________  ________  ________  ________  ___  ___  _______
// |\___   ___\\   __  \|\   __  \|\   __  \|\  \|\  \|\  ___ \
// \|___ \  \_\ \  \|\  \ \  \|\  \ \  \|\  \ \  \\\  \ \   __/|
//     \ \  \ \ \  \\\  \ \   _  _\ \  \\\  \ \  \\\  \ \  \_|/__
//      \ \  \ \ \  \\\  \ \  \\  \\ \  \\\  \ \  \\\  \ \  \_|\ \
//       \ \__\ \ \_______\ \__\\ _\\ \_____  \ \_______\ \_______\
//        \|__|  \|_______|\|__|\|__|\|___| \__\|_______|\|_______|

import "./BorrowAbstract.sol";

contract ETHBorrow is BorrowAbstract {
    using SafeMath for uint256;

     // Allows a user to borrow Torque USD
    function borrow(uint borrowAmount, uint usdBorrowAmount) public payable nonReentrant(){
        // Get the amount of USD the user is allowed to mint for the given asset
	    (uint mintable, bool canMint) = IUSDEngine(engine).getMintableTUSD(baseAsset, msg.sender, borrowAmount);
        // Ensure user is allowed to mint and doesn't exceed mintable limit
        require(canMint, "User can not mint more TUSD");
        require(mintable > tusdBorrowAmount, "Exceeds borrow amount");

        uint supplyAmount = msg.value;
        BorrowInfo storage userBorrowInfo = borrowInfoMap[msg.sender];

        // Calculate the maximum borrowable amount for the user based on collateral
        uint maxBorrow = getBorrowableUsdc(supplyAmount.add(userBorrowInfo.supplied));

        // Calculate the amount user can still borrow.
        uint borrowable = maxBorrow.sub(userBorrowInfo.borrowed);

        // Ensure the user isn't trying to borrow more than what's allowed
        require(borrowable >= borrowAmount, "Borrow cap exceeded");

        // If user has borrowed before, calculate accrued interest and reward
        uint accruedInterest = 0;
        uint reward = 0;
        if (userBorrowInfo.borrowed > 0) {
            accruedInterest = calculateInterest(userBorrowInfo.borrowed, userBorrowInfo.borrowTime);
            reward = RewardUtil(rewardUtil).calculateReward(
                userBorrowInfo.baseBorrowed,
                userBorrowInfo.borrowTime
            );
        }

        // Update the user's borrowing information
        userBorrowInfo.baseBorrowed = userBorrowInfo.baseBorrowed.add(tusdBorrowAmount);
        userBorrowInfo.borrowed = userBorrowInfo.borrowed.add(borrowAmount).add(accruedInterest);
        if (reward > 0) {
            userBorrowInfo.reward = userBorrowInfo.reward.add(reward);
        }
        userBorrowInfo.supplied = userBorrowInfo.supplied.add(supplyAmount);
        userBorrowInfo.borrowTime = block.timestamp;

        bytes[] memory callData = new bytes[](2);

        bytes memory supplyAssetCalldata = abi.encode(comet, address(this), supplyAmount);
        callData[0] = supplyAssetCalldata;

        bytes memory withdrawAssetCalldata = abi.encode(
            comet,
            address(this),
            baseAsset,
            borrowAmount
        );
        callData[1] = withdrawAssetCalldata;

        // Invoke actions in the Bulker for optimization
        IBulker(bulker).invoke{ value: supplyAmount }(buildBorrowAction(), callData);

        ERC20(baseAsset).approve(address(engine), borrowAmount);

        // Check the balance of TUSD before the minting operation
        uint tusdBefore = ERC20(tusd).balanceOf(address(this));

        // Mint the USD equivalent of the borrowed asset
        IUSDEngine(engine).depositCollateralAndMintTusd{value:0}(baseAsset, borrowAmount, usdBorrowAmount, msg.sender);

        // Ensure the expected TUSD amount was minted
        uint expectedTusd = tusdBefore.add(tusdBorrowAmount);
        require(expectedTusd == ERC20(tusd).balanceOf(address(this)), "Invalid amount");

        require(ERC20(tusd).transfer(msg.sender, tusdBorrowAmount), "Transfer token failed");
        totalBorrow = totalBorrow.add(tusdBorrowAmount);
        totalSupplied = totalSupplied.add(supplyAmount);
    }

    // Allows users to repay their borrowed assets
    function repay(uint tusdRepayAmount) public nonReentrant {
        BorrowInfo storage userBorrowInfo = borrowInfoMap[msg.sender];

        (uint withdrawUsdcAmountFromEngine, bool burnable) = IUSDEngine(engine).getBurnableTUSD(baseAsset, msg.sender, usdRepayAmount);
        require(burnable, "Not burnable");
        withdrawUsdcAmountFromEngine = withdrawUsdcAmountFromEngine.mul(100 - repaySlippage).div(100);
        require(userBorrowInfo.borrowed >= withdrawUsdcAmountFromEngine, "Exceeds current borrowed amount");
        require(ERC20(usd).transferFrom(msg.sender,address(this), usdRepayAmount), "Transfer asset failed");

        uint baseAssetBalanceBefore = ERC20(baseAsset).balanceOf(address(this));

        ERC20(tusd).approve(address(engine), tusdRepayAmount);

        IUSDEngine(engine).redeemCollateralForTusd(baseAsset, withdrawUsdcAmountFromEngine, usdRepayAmount, msg.sender);

        uint baseAssetBalanceExpected = baseAssetBalanceBefore.add(withdrawUsdcAmountFromEngine);
        require(
            baseAssetBalanceExpected == ERC20(baseAsset).balanceOf(address(this)),
            "Invalid USDC claim to Engine"
        );

        uint accruedInterest = calculateInterest(
            userBorrowInfo.borrowed,
            userBorrowInfo.borrowTime
        );
        uint reward = RewardUtil(rewardUtil).calculateReward(
            userBorrowInfo.baseBorrowed,
            userBorrowInfo.borrowTime
        ) + userBorrowInfo.reward;
        userBorrowInfo.borrowed = userBorrowInfo.borrowed.add(accruedInterest);

        uint repayUsdcAmount = withdrawUsdcAmountFromEngine;
        if (repayUsdcAmount > userBorrowInfo.borrowed) {
            repayUsdcAmount = userBorrowInfo.borrowed;
        }
        uint repayTusd = userBorrowInfo.baseBorrowed.mul(repayUsdcAmount).div(
            userBorrowInfo.borrowed
        );

        uint withdrawAssetAmount = userBorrowInfo.supplied.mul(repayUsdcAmount).div(
            userBorrowInfo.borrowed
        );

        bytes[] memory callData = new bytes[](2);

        bytes memory supplyAssetCalldata = abi.encode(
            comet,
            address(this),
            baseAsset,
            repayUsdcAmount
        );
        callData[0] = supplyAssetCalldata;

        bytes memory withdrawAssetCalldata = abi.encode(comet, address(this), withdrawAssetAmount);
        callData[1] = withdrawAssetCalldata;

        ERC20(baseAsset).approve(comet, repayUsdcAmount);
        IBulker(bulker).invoke(buildRepay(), callData);

        userBorrowInfo.baseBorrowed = userBorrowInfo.baseBorrowed.sub(repayTusd);
        userBorrowInfo.borrowed = userBorrowInfo.borrowed.sub(repayUsdcAmount);
        userBorrowInfo.supplied = userBorrowInfo.supplied.sub(withdrawAssetAmount);
        userBorrowInfo.borrowTime = block.timestamp;
        userBorrowInfo.reward = 0;
        if (reward > 0) {
            require(
                ERC20(rewardToken).balanceOf(address(this)) >= reward,
                "Insuffient balance to pay reward"
            );
            require(ERC20(rewardToken).transfer(msg.sender, reward), "Transfer reward failed");
        }

        (bool success, ) = msg.sender.call{ value: withdrawAssetAmount }("");
        require(success, "Transfer ETH failed");
        totalBorrow = totalBorrow.sub(repayTusd);
        totalSupplied = totalSupplied.sub(withdrawAssetAmount);
    }

    // View function to get the total amount supplied by a user
    function getTotalAmountSupplied(address user) public view returns (uint) {
        BorrowInfo storage userInfo = borrowInfoMap[user];
        return userInfo.supplied;
    }

    // View function to get the total amount borrowed by a user
    function getTotalAmountBorrowed(address user) public view returns (uint) {
        BorrowInfo storage userInfo = borrowInfoMap[user];
        return userInfo.borrowed;
    }

    function buildBorrowAction() pure override public returns(bytes32[] memory) {
        bytes32[] memory actions = new bytes32[](2);
        actions[0] = ACTION_SUPPLY_ETH;
        actions[1] = ACTION_WITHDRAW_ASSET;
        return actions;
    }
    function buildRepay() pure override public returns(bytes32[] memory) {
        bytes32[] memory actions = new bytes32[](2);

        actions[0] = ACTION_SUPPLY_ASSET;
        actions[1] = ACTION_WITHDRAW_ETH;
        return actions;
    }
}
