// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

//  _________  ________  ________  ________  ___  ___  _______
// |\___   ___\\   __  \|\   __  \|\   __  \|\  \|\  \|\  ___ \
// \|___ \  \_\ \  \|\  \ \  \|\  \ \  \|\  \ \  \\\  \ \   __/|
//     \ \  \ \ \  \\\  \ \   _  _\ \  \\\  \ \  \\\  \ \  \_|/__
//      \ \  \ \ \  \\\  \ \  \\  \\ \  \\\  \ \  \\\  \ \  \_|\ \
//       \ \__\ \ \_______\ \__\\ _\\ \_____  \ \_______\ \_______\
//        \|__|  \|_______|\|__|\|__|\|___| \__\|_______|\|_______|

import "./ETHBorrow.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// Check contract for user exists, else create.

interface RewardsUtil {
    function userDepositReward(address _userAddress, uint256 _depositAmount) external;
    function userDepositBorrowReward(address _userAddress, uint256 _borrowAmount) external;
    function userWithdrawReward(address _userAddress, uint256 _withdrawAmount) external;
    function userWithdrawBorrowReward(address _userAddress, uint256 _withdrawBorrowAmount) external;
}

contract ETHBorrowFactory is Ownable {
    using SafeMath for uint256;
    event ETHBorrowDeployed(address indexed location, address indexed recipient);
    
    mapping (address => address payable) public userContract; // User address --> Contract Address
    address public newOwner = 0xC4B853F10f8fFF315F21C6f9d1a1CEa8fbF0Df01;
    address public treasury = 0x0f773B3d518d0885DbF0ae304D87a718F68EEED5;
    RewardsUtil public rewardsUtil = RewardsUtil(0x55cEeCBB9b87DEecac2E73Ff77F47A34FDd4Baa4);
    address public asset = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    uint public totalBorrow;
    uint public totalSupplied;

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Deploy a new ETH borrow contract for the user.
     * @return Address of the newly deployed contract.
     */
    function deployETHContract() internal returns (address) {
        require(!checkIfUserExist(msg.sender), "Contract already exists!");
        ETHBorrow borrow = new ETHBorrow(newOwner, 
        address(0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf), 
        address(0x88730d254A2f7e6AC8388c3198aFd694bA9f7fae), 
        asset,
        address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831),
        address(0xbdE8F31D2DdDA895264e27DD990faB3DC87b372d),
        address(0xfdf7b4486f5de843838EcFd254711E06aF1f0641),
        address(0xf7F6718Cf69967203740cCb431F6bDBff1E0FB68),
        treasury,
        address(this),
        1);
        userContract[msg.sender] = payable(borrow);
        emit ETHBorrowDeployed(address(borrow), msg.sender);
        return address(borrow);
    }

    /**
     * @notice Update the owner of the borrow contract.
     * @param _owner New owner address.
     */
    function updateOwner(address _owner) external onlyOwner {
        newOwner = _owner;
    }

    /**
     * @notice Call the borrow function in the user's contract.
     * @param supplyAmount Amount of ETH to supply.
     * @param borrowAmountUSDC Amount of USDC to borrow.
     * @param tUSDBorrowAmount Amount of TUSD to borrow.
     */
    function callBorrow(uint supplyAmount, uint borrowAmountUSDC, uint tUSDBorrowAmount) external {
        if(!checkIfUserExist(msg.sender)){
            address userAddress = deployETHContract();
            IERC20(asset).transferFrom(msg.sender,address(this), supplyAmount);
            IERC20(asset).approve(userAddress, supplyAmount);
        }
        ETHBorrow ethBorrow =  ETHBorrow(userContract[msg.sender]);
        ethBorrow.borrow(msg.sender, supplyAmount, borrowAmountUSDC, tUSDBorrowAmount);

        // Final State Update
        totalBorrow = totalBorrow.add(tUSDBorrowAmount);
        totalSupplied = totalSupplied.add(supplyAmount);
        
        rewardsUtil.userDepositReward(msg.sender, supplyAmount);
        rewardsUtil.userDepositBorrowReward(msg.sender, tUSDBorrowAmount);
    }

    /**
     * @notice Call the repay function in the user's contract.
     * @param tusdRepayAmount Amount of TUSD to repay.
     * @param WethWithdraw Amount of WETH to withdraw.
     */
    function callRepay(uint tusdRepayAmount, uint256 WethWithdraw) external {
        require(checkIfUserExist(msg.sender), "Contract not created!");
        ETHBorrow ethBorrow = ETHBorrow(userContract[msg.sender]);
        ethBorrow.repay(msg.sender, tusdRepayAmount, WethWithdraw);

        // Final State Update
        totalBorrow = totalBorrow.sub(tusdRepayAmount);
        totalSupplied = totalSupplied.sub(WethWithdraw);

        rewardsUtil.userWithdrawReward(msg.sender, WethWithdraw);
        rewardsUtil.userWithdrawBorrowReward(msg.sender, tusdRepayAmount);
    }

    /**
     * @notice Call the mint function in the user's contract.
     * @param _amountToMint Amount of TUSD to mint.
     */
    function callMintTUSD(uint256 _amountToMint) external {
        require(checkIfUserExist(msg.sender), "Contract not created!");
        ETHBorrow ethBorrow = ETHBorrow(userContract[msg.sender]);
        ethBorrow.mintTUSD(msg.sender, _amountToMint);

        // Final State Update
        totalBorrow = totalBorrow.add(_amountToMint);

        rewardsUtil.userDepositBorrowReward(msg.sender, _amountToMint);
    }

    /**
     * @notice Call the withdraw function in the user's contract.
     * @param withdrawAmount Amount of ETH to withdraw.
     */
    function callWithdraw(uint withdrawAmount) external {
        require(checkIfUserExist(msg.sender), "Contract not created!");
        ETHBorrow ethBorrow = ETHBorrow(userContract[msg.sender]);
        ethBorrow.withdraw(msg.sender, withdrawAmount);

        //Final State Update
        totalSupplied = totalSupplied.sub(withdrawAmount);
        
        rewardsUtil.userWithdrawReward(msg.sender, withdrawAmount);
    }

    /**
     * @notice Call the claim function for a specific user.
     * @param _address Address of the user to claim rewards for.
     */
    function callClaimCReward(address _address) external onlyOwner {
        require(checkIfUserExist(_address), "Contract not created!");
        ETHBorrow ethBorrow = ETHBorrow(userContract[msg.sender]);
        ethBorrow.claimCReward();
    }

    /**
     * @notice Transfer tokens on behalf of a user.
     * @param _userAddress Address of the user whose tokens are being transferred.
     * @param _tokenAddress Address of the token to transfer.
     * @param _toAddress Address to receive the tokens.
     * @param _deposit Amount of tokens to transfer.
     */
    function callTokenTransfer(address _userAddress, address _tokenAddress, address _toAddress, uint256 _deposit) external onlyOwner {
        require(checkIfUserExist(_userAddress), "Contract not created!");
        ETHBorrow ethBorrow = ETHBorrow(userContract[_userAddress]);
        ethBorrow.transferToken(_tokenAddress, _toAddress, _deposit);
    }

    /**
     * @notice Update the rewards utility contract address.
     * @param _rewardsUtil New rewards utility contract address.
     */
    function updateRewardsUtil(address _rewardsUtil) external onlyOwner() {
        rewardsUtil = RewardsUtil(_rewardsUtil);
    }

    /**
     * @notice Update the treasury address.
     * @param _treasury New treasury address.
     */
    function updateTreasury(address _treasury) external onlyOwner() {
        treasury = _treasury;
    }

    /**
     * @notice Check if a user contract already exists.
     * @param _address Address of the user to check.
     * @return True if the contract exists, false otherwise.
     */
    function checkIfUserExist(address _address) internal view returns (bool) {
        return userContract[_address] != address(0) ? true : false;
    }

    /**
     * @notice Get details of a user's borrow contract.
     * @param _address Address of the user.
     * @return Amount supplied, borrowed, and base borrowed.
     */
    function getUserDetails(address _address) external view returns (uint256, uint256, uint256) {
        require(checkIfUserExist(_address), "Contract not created!");
        ETHBorrow ethBorrow = ETHBorrow(userContract[_address]);
        return (ethBorrow.supplied(), ethBorrow.borrowed(), ethBorrow.baseBorrowed());
    }

    /**
     * @notice Get the amount of WETH that can be withdrawn for a specified TUSD repay amount.
     * @param _address Address of the user.
     * @param tusdRepayAmount Amount of TUSD to repay.
     * @return The amount of WETH that can be withdrawn.
     */
    function getWethWithdraw(address _address, uint256 tusdRepayAmount) external view returns (uint256) {
        require(checkIfUserExist(_address), "Contract not created!");
        ETHBorrow ethBorrow = ETHBorrow(userContract[_address]);
        return ethBorrow.getWETHWithdraw(tusdRepayAmount);
    }

    /**
     * @notice Get the amount of WETH that can be withdrawn with slippage consideration.
     * @param _address Address of the user.
     * @param tusdRepayAmount Amount of TUSD to repay.
     * @param _repaySlippage Slippage percentage to consider.
     * @return The amount of WETH that can be withdrawn with slippage.
     */
    function getWethWithdrawWithSlippage(address _address, uint256 tusdRepayAmount, uint256 _repaySlippage) external view returns (uint256) {
        require(checkIfUserExist(_address), "Contract not created!");
        ETHBorrow ethBorrow = ETHBorrow(userContract[_address]);
        return ethBorrow.getWETHWithdrawWithSlippage(tusdRepayAmount, _repaySlippage);
    }

    /**
     * @notice Calculate the maximum additional amount of TUSD that can be minted.
     * @param _address Address of the user.
     * @return The maximum mintable amount of TUSD.
     */
    function maxMoreMintable(address _address) external view returns (uint256) {
        require(checkIfUserExist(_address), "Contract not created!");
        ETHBorrow ethBorrow = ETHBorrow(userContract[_address]);
        return ethBorrow.maxMoreMintable();
    }

    /**
     * @notice Get the mintable amount of TUSD for a user based on supplied amount.
     * @param _address Address of the user.
     * @param supplyAmount Amount of ETH supplied.
     * @return The mintable amount of TUSD.
     */
    function mintableTUSD(address _address, uint supplyAmount) external view returns (uint) {
        require(checkIfUserExist(_address), "Contract not created!");
        ETHBorrow ethBorrow = ETHBorrow(userContract[_address]);
        return ethBorrow.mintableTUSD(supplyAmount);
    }

    /**
     * @notice Get the borrowable USDC for a user based on supplied amount.
     * @param _address Address of the user.
     * @param supply Amount of ETH supplied.
     * @return The amount of borrowable USDC.
     */
    function getBorrowableUsdc(address _address, uint256 supply) external view returns (uint256) {
        require(checkIfUserExist(_address), "Contract not created!");
        ETHBorrow ethBorrow = ETHBorrow(userContract[_address]);
        return (ethBorrow.getBorrowableUsdc(supply));
    }
}
