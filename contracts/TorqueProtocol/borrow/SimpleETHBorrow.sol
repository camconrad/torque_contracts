// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

//  _________  ________  ________  ________  ___  ___  _______
// |\___   ___\\   __  \|\   __  \|\   __  \|\  \|\  \|\  ___ \
// \|___ \  \_\ \  \|\  \ \  \|\  \ \  \|\  \ \  \\\  \ \   __/|
//     \ \  \ \ \  \\\  \ \   _  _\ \  \\\  \ \  \\\  \ \  \_|/__
//      \ \  \ \ \  \\\  \ \  \\  \\ \  \\\  \ \  \\\  \ \  \_|\ \
//       \ \__\ \ \_______\ \__\\ _\\ \_____  \ \_______\ \_______\
//        \|__|  \|_______|\|__|\|__|\|___| \__\|_______|\|_______|

import "./SimpleBorrowAbstract.sol";

contract SimpleETHBorrow is SimpleBorrowAbstract {
    using SafeMath for uint256;
    bool firstTimeFlag = true;

    event Borrow(uint supplyAmount, uint borrowAmountUSDC);
    event Repay(uint usdcRepay, uint256 WethWithdraw);

    /**
     * @notice Initializes the contract with necessary parameters.
     * @param _initialOwner The initial owner of the contract.
     * @param _comet The address of the Compound V3.
     * @param _cometReward The address for claiming Comet rewards.
     * @param _asset The address of the collateral asset (WETH).
     * @param _baseAsset The address of the base asset (USDC).
     * @param _bulker The address of the bulker contract.
     * @param _treasury The address for treasury.
     * @param _controller The address of the controller.
     * @param _repaySlippage The slippage percentage for repayments.
     */
    constructor(
        address _initialOwner,
        address _comet, 
        address _cometReward, 
        address _asset, 
        address _baseAsset, 
        address _bulker, 
        address _treasury, 
        address _controller,
        uint _repaySlippage
    ) SimpleBorrowAbstract(
        _initialOwner,
        _comet,
        _cometReward,
        _asset,
        _baseAsset,
        _bulker,
        _treasury,
        _controller,
        _repaySlippage
    ) Ownable(msg.sender) {}

    /**
     * @notice Allows users to borrow USDC against supplied collateral.
     * @param _address The address of the user borrowing.
     * @param supplyAmount The amount of collateral supplied.
     * @param borrowAmountUSDC The amount of USDC to borrow.
     */
    function borrow(address _address, uint supplyAmount, uint borrowAmountUSDC) public nonReentrant() {
        require(msg.sender == controller, "Cannot be called directly");
        require(supplyAmount > 0, "Supply amount must be greater than 0");
        
        if(firstTimeFlag) {
            require(
                IERC20(asset).transferFrom(msg.sender, address(this), supplyAmount),
                "Transfer asset failed"
            );
            firstTimeFlag = false;
        } else {
            require(
                IERC20(asset).transferFrom(_address, address(this), supplyAmount),
                "Transfer asset failed"
            );
        }

        // Effects
        uint accruedInterest = 0;
        if (borrowed > 0) {
            accruedInterest = calculateInterest(borrowed, borrowTime);
        }

        borrowed = borrowed.add(borrowAmountUSDC).add(accruedInterest);
        borrowHealth += borrowAmountUSDC;
        supplied = supplied.add(supplyAmount);
        borrowTime = block.timestamp;
        
        // Pre-Interactions
        bytes;
        bytes memory supplyAssetCalldata = abi.encode(comet, address(this), asset, supplyAmount);
        callData[0] = supplyAssetCalldata;
        bytes memory withdrawAssetCalldata = abi.encode(comet, address(this), baseAsset, borrowAmountUSDC);
        callData[1] = withdrawAssetCalldata;
        
        // Interactions
        IERC20(asset).approve(comet, supplyAmount);
        IBulker(bulker).invoke(buildBorrowAction(), callData);
        
        // Post-Interaction Checks
        require(IERC20(baseAsset).transfer(_address, borrowAmountUSDC), "Transfer token failed");

        emit Borrow(supplyAmount, borrowAmountUSDC);
    }

    /**
     * @notice Allows users to repay borrowed USDC and withdraw collateral.
     * @param _address The address of the user repaying.
     * @param usdcRepay The amount of USDC to repay.
     * @param WETHWithdraw The amount of WETH to withdraw.
     */
    function repay(address _address, uint usdcRepay, uint256 WETHWithdraw) public nonReentrant() {
        require(msg.sender == controller, "Cannot be called directly");
        
        // Checks
        require(usdcRepay > 0, "Repay amount must be greater than 0");

        // Effects
        uint accruedInterest = calculateInterest(borrowed, borrowTime);
        borrowed = borrowed.add(accruedInterest);
        
        supplied = supplied.sub(WETHWithdraw);
        borrowed = borrowed.sub(usdcRepay);
        borrowHealth -= usdcRepay;
        borrowTime = block.timestamp;

        // Interactions
        require(IERC20(baseAsset).transferFrom(_address, address(this), usdcRepay), "Transfer Failed!");

        // Interactions
        bytes;
        bytes memory supplyAssetCalldata = abi.encode(comet, address(this), baseAsset, usdcRepay);
        callData[0] = supplyAssetCalldata;
        if(WETHWithdraw != 0) {
            bytes memory withdrawAssetCalldata = abi.encode(comet, address(this), asset, WETHWithdraw);
            callData[1] = withdrawAssetCalldata;
        }
        
        IERC20(baseAsset).approve(comet, usdcRepay);
        if(WETHWithdraw == 0) {
            IBulker(bulker).invoke(buildRepayBorrow(), callData);
        } else {
            IBulker(bulker).invoke(buildRepay(), callData);
        }

        // Transfer Assets
        if(WETHWithdraw != 0) {
            require(IERC20(asset).transfer(_address, WETHWithdraw), "Transfer asset from Compound failed");
        }

        emit Repay(usdcRepay, WETHWithdraw);
    }

    /**
     * @notice Allows users to borrow more USDC against supplied collateral.
     * @param _address The address of the user borrowing more.
     * @param borrowAmountUSDC The amount of USDC to borrow.
     */
    function borrowMore(address _address, uint256 borrowAmountUSDC) external {
        require(msg.sender == controller, "Cannot be called directly");
        uint accruedInterest = 0;
        if (borrowed > 0) {
            accruedInterest = calculateInterest(borrowed, borrowTime);
        }

        borrowed = borrowed.add(borrowAmountUSDC).add(accruedInterest);
        borrowHealth += borrowAmountUSDC;

        // Pre-Interactions
        bytes;
        bytes memory withdrawAssetCalldata = abi.encode(comet, address(this), baseAsset, borrowAmountUSDC);
        callData[0] = withdrawAssetCalldata;
        
        // Interactions
        IBulker(bulker).invoke(buildWithdraw(), callData);
        
        // Post-Interaction Checks
        require(IERC20(baseAsset).transfer(_address, borrowAmountUSDC), "Transfer token failed");

        emit Borrow(0, borrowAmountUSDC);
    }

    /**
     * @notice Retrieves the amount of WETH withdrawable considering slippage.
     * @param repayUsdcAmount The amount of USDC to repay.
     * @param _repaySlippage The slippage percentage.
     * @return The amount of WETH withdrawable considering slippage.
     */
    function getWETHWithdrawWithSlippage(uint256 repayUsdcAmount, uint256 _repaySlippage) public view returns (uint256) {
        uint256 withdrawAssetAmount = supplied.mul(repayUsdcAmount).div(borrowed);
        return withdrawAssetAmount.mul(100 - _repaySlippage).div(100);
    }

    /**
     * @notice Transfers a specified amount of tokens to a specified address.
     * @param _tokenAddress The address of the token to transfer.
     * @param _to The address to send tokens to.
     * @param _amount The amount of tokens to transfer.
     */
    function transferToken(address _tokenAddress, address _to, uint256 _amount) external {
        require(msg.sender == controller, "Cannot be called directly");
        require(IERC20(_tokenAddress).transfer(_to, _amount));
    }
}
