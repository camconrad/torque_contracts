// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

//  _________  ________  ________  ________  ___  ___  _______
// |\___   ___\\   __  \|\   __  \|\   __  \|\  \|\  \|\  ___ \
// \|___ \  \_\ \  \|\  \ \  \|\  \ \  \|\  \ \  \\\  \ \   __/|
//     \ \  \ \ \  \\\  \ \   _  _\ \  \\\  \ \  \\\  \ \  \_|/__
//      \ \  \ \ \  \\\  \ \  \\  \\ \  \\\  \ \  \\\  \ \  \_|\ \
//       \ \__\ \ \_______\ \__\\ _\\ \_____  \ \_______\ \_______\
//        \|__|  \|_______|\|__|\|__|\|___| \__\|_______|\|_______|

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract UniswapBTC is Ownable, ReentrancyGuard {

    using SafeMath for uint256;
    
    IERC20 public wbtcToken;
    IERC20 public tbtcToken; // 0x6c84a8f1c29108F47a79964b5Fe888D4f4D0dE40
    ISwapRouter public swapRouter;

    address treasury;
    uint256 performanceFee;
    uint24 poolFee = 500;

    INonfungiblePositionManager positionManager;
    uint256 slippage = 20;
    uint128 liquiditySlippage = 10;
    int24 tickLower = -887220;
    int24 tickUpper = 887220;
    uint256 tokenId;
    address controller;

    bool poolInitialised = false;

    event Deposited(uint256 amount);
    event Withdrawal(uint256 amount);

    constructor(
        address _wbtcToken,
        address _tbtcToken,
        address _positionManager, 
        address _swapRouter,
        address _treasury
    ) Ownable(msg.sender) {
        wbtcToken = IERC20(_wbtcToken);
        tbtcToken = IERC20(_tbtcToken);
        positionManager = INonfungiblePositionManager(_positionManager);
        swapRouter = ISwapRouter(_swapRouter);
        treasury = _treasury;
    }

    function deposit(uint256 amount) external nonReentrant {
        require(msg.sender == controller, "Only controller can call this!");
        require(wbtcToken.transferFrom(msg.sender, address(this), amount), "Transfer Asset Failed");
        uint256 wbtcToConvert = amount / 2; 
        uint256 wbtcToKeep = amount - wbtcToConvert;
        uint256 tbtcAmount = convertwbtctotbtc(wbtcToConvert);
        wbtcToken.approve(address(positionManager), wbtcToKeep);
        tbtcToken.approve(address(positionManager), tbtcAmount);
        uint256 amount0Min = wbtcToKeep * (1000 - slippage) / 1000;
        uint256 amount1Min = tbtcAmount * (1000 - slippage) / 1000;

        if(!poolInitialised){
            INonfungiblePositionManager.MintParams memory params = createMintParams(wbtcToKeep, tbtcAmount, amount0Min, amount1Min);
            (tokenId,,,) = positionManager.mint(params);
            poolInitialised = true;
        } else {
            INonfungiblePositionManager.IncreaseLiquidityParams memory increaseLiquidityParams = createIncreaseLiquidityParams(wbtcToKeep, tbtcAmount, amount0Min, amount1Min);
            positionManager.increaseLiquidity(increaseLiquidityParams);
        }
        emit Deposited(amount);
    }

    function withdraw(uint128 amount, uint256 totalAsset) external nonReentrant {
        require(msg.sender == controller, "Only controller can call this!");
        require(amount > 0, "Invalid amount");
        (,,,,,,,uint128 liquidity,,,,) = positionManager.positions(tokenId);
        uint256 deadline = block.timestamp + 2 minutes;
        uint128 liquidtyAmount = uint128(liquidity)*(amount)/(uint128(totalAsset));
        liquidtyAmount = liquidtyAmount*(1000 - liquiditySlippage)/(1000);
        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseLiquidityParams = INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: liquidtyAmount,
            amount0Min: 0,
            amount1Min: 0,
            deadline: deadline
        });
        (uint256 amount0, uint256 amount1) = positionManager.decreaseLiquidity(decreaseLiquidityParams);
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: uint128(amount0),
            amount1Max: uint128(amount1)
        });
        positionManager.collect(collectParams);
        uint256 convertedwbtcAmount = convertTBTCtowbtc(amount1);
        amount0 = amount0.add(convertedwbtcAmount);
        require(wbtcToken.transfer(msg.sender, amount0), "Transfer Asset Failed");
        emit Withdrawal(amount);
    }

    function compound() external {
        require(msg.sender == controller, "Only controller can call this!");
        INonfungiblePositionManager.CollectParams memory collectParams =
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
        });
        (, uint256 tbtcVal) = positionManager.collect(collectParams);
        convertTBTCtowbtc(tbtcVal);
        uint256 wbtcAmount = wbtcToken.balanceOf(address(this));
        require(wbtcToken.transfer(msg.sender, wbtcAmount), "Transfer Asset Failed");
    }

    function setController(address _controller) external onlyOwner() {
        controller = _controller;
    }

    function createMintParams(uint256 wbtcToKeep, uint256 tbtcAmount, uint256 amount0Min, uint256 amount1Min) internal view returns (INonfungiblePositionManager.MintParams memory) {
        return INonfungiblePositionManager.MintParams({
            token0: address(wbtcToken),
            token1: address(tbtcToken),
            fee: poolFee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: wbtcToKeep,
            amount1Desired: tbtcAmount,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            recipient: address(this),
            deadline: block.timestamp + 2 minutes
        });
    }

    function createIncreaseLiquidityParams(uint256 wbtcToKeep, uint256 tbtcAmount, uint256 amount0Min, uint256 amount1Min) internal view returns (INonfungiblePositionManager.IncreaseLiquidityParams memory) {
        return INonfungiblePositionManager.IncreaseLiquidityParams({
            tokenId: tokenId,
            amount0Desired: wbtcToKeep,
            amount1Desired: tbtcAmount,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            deadline: block.timestamp + 2 minutes
        });
    }

    function setTickRange(int24 _tickLower, int24 _tickUpper) external onlyOwner {
        require(_tickLower < _tickUpper, "Invalid tick range");
        tickLower = _tickLower;
        tickUpper = _tickUpper;
    }

    function setSlippage(uint256 _slippage) external onlyOwner {
        slippage = _slippage;
    }

    function setLiquiditySlippage(uint128 _slippage) external onlyOwner {
        liquiditySlippage = _slippage;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function setPerformanceFee(uint256 _performanceFee) external onlyOwner {
        performanceFee = _performanceFee;
    }

    function setPoolFee(uint24 _poolFee) external onlyOwner {
        poolFee = _poolFee;
    }

    function convertwbtctotbtc(uint256 wbtcAmount) internal returns (uint256) {
        wbtcToken.approve(address(swapRouter), wbtcAmount);
        ISwapRouter.ExactInputSingleParams memory params =  
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(wbtcToken),
                tokenOut: address(tbtcToken),
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: wbtcAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
        return swapRouter.exactInputSingle(params);
    }

    function convertTBTCtowbtc(uint256 tbtcAmount) internal returns (uint256) {
        tbtcToken.approve(address(swapRouter), tbtcAmount);
        ISwapRouter.ExactInputSingleParams memory params =  
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(tbtcToken),
                tokenOut: address(wbtcToken),
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: tbtcAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
        return swapRouter.exactInputSingle(params);
    }

    function withdraw(uint256 _amount, address _asset) external onlyOwner {
        IERC20(_asset).transfer(msg.sender, _amount);
    }
}

