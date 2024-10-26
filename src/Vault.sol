// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {
    AccessControlUpgradeable,
    Address,
    ERC20PermitUpgradeable,
    ERC20Upgradeable,
    IERC20,
    IERC20Metadata,
    Math,
    ReentrancyGuardUpgradeable,
    SafeERC20
} from "./Common.sol";

import {IVault} from "src/interface/IVault.sol";
import {IStrategy} from "src/interface/IStrategy.sol";
import {IRateProvider} from "src/interface/IRateProvider.sol";

contract Vault is IVault, ERC20PermitUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;

    function decimals() public view virtual override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        AssetStorage storage assetStorage = _getAssetStorage();
        return assetStorage.assets[assetStorage.list[0]].decimals;
    }

    function asset() public view returns (address) {
        return _getAssetStorage().list[0];
    }

    function totalAssets() public view returns (uint256) {
        return _getVaultStorage().totalAssets;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(asset(), assets, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(asset(), shares, Math.Rounding.Floor);
    }

    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public view returns (uint256) {
        if (paused()) return 0;
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        if (paused()) return 0;

        // Here we return whichever is less, the available base assets in the buffer, or the user's
        // vault token balance converted to base asset value
        uint256 ownerAssets = _convertToAssets(asset(), balanceOf(owner), Math.Rounding.Floor);
        // The buffer strategy must have the same base underlying asset as the vault
        uint256 idleBalance = IERC20(asset()).balanceOf(address(this));
        // Fetch available base assets available to withdraw from buffer
        uint256 buffferBalance = IStrategy(_getVaultStorage().bufferStrategy).previewWithdraw(ownerAssets);
        return Math.min(idleBalance + buffferBalance, ownerAssets);
    }

    // QUESTION: How to handle this in v1 with async withdraws.
    function maxRedeem(address owner) public view returns (uint256) {
        if (paused()) return 0;
        // TODO: Implement a check for available assets from Research Strategy
        return balanceOf(owner);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToShares(asset(), assets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssets(asset(), shares, Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(asset(), assets, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(asset(), shares, Math.Rounding.Floor);
    }

    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256) {
        if (paused()) revert Paused();

        uint256 shares = previewDeposit(assets);
        _deposit(asset(), _msgSender(), receiver, assets, shares);

        return shares;
    }

    function mint(uint256 shares, address receiver) public virtual nonReentrant returns (uint256) {
        if (paused()) revert Paused();

        uint256 assets_ = previewMint(shares);
        _deposit(asset(), _msgSender(), receiver, assets_, shares);

        return assets_;
    }

    function withdraw(uint256 assets, address receiver, address owner) public nonReentrant returns (uint256) {
        if (paused()) revert Paused();

        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 shares = previewWithdraw(assets);

        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    // QUESTION: How to handle this in v1 with async withdraws
    function redeem(uint256 shares, address receiver, address owner) public nonReentrant returns (uint256) {
        if (paused()) revert Paused();

        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);

        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return assets;
    }

    //// 4626-MAX ////

    function getAssets() public view returns (address[] memory) {
        return _getAssetStorage().list;
    }

    function getAsset(address asset_) public view returns (AssetParams memory) {
        return _getAssetStorage().assets[asset_];
    }

    function getStrategies() public view returns (address[] memory) {
        return _getStrategyStorage().list;
    }

    function getStrategy(address asset_) public view returns (StrategyParams memory) {
        return _getStrategyStorage().strategies[asset_];
    }

    function previewDepositAsset(address asset_, uint256 assets_) public view returns (uint256) {
        if (!_getAssetStorage().assets[asset_].active) revert InvalidAsset();
        return _convertToShares(asset_, assets_, Math.Rounding.Floor);
    }

    function depositAsset(address asset_, uint256 assets_, address receiver) public nonReentrant returns (uint256) {
        if (paused()) revert Paused();
        if (!_getAssetStorage().assets[asset_].active) revert InvalidAsset();

        uint256 shares = previewDepositAsset(asset_, assets_);
        _deposit(asset_, _msgSender(), receiver, assets_, shares);

        return shares;
    }

    function paused() public view returns (bool) {
        return _getVaultStorage().paused;
    }

    function rateProvider() public view returns (address) {
        return _getVaultStorage().rateProvider;
    }

    function bufferStrategy() public view returns (address) {
        return _getVaultStorage().bufferStrategy;
    }

    function processAccounting() public {
        AssetStorage storage assetStorage = _getAssetStorage();
        StrategyStorage storage strategyStorage = _getStrategyStorage();
        uint256 totalBaseBalance = 0;

        for (uint256 i = 0; i < assetStorage.list.length; i++) {
            address asset_ = assetStorage.list[i];
            uint256 idleBalance = IERC20(asset_).balanceOf(address(this));
            assetStorage.assets[asset_].idleBalance = idleBalance;
            totalBaseBalance += _convertAssetToBase(asset_, idleBalance);
        }

        for (uint256 i = 0; i < strategyStorage.list.length; i++) {
            address strategy = strategyStorage.list[i];
            uint256 idleBalance = IERC20(strategy).balanceOf(address(this));
            strategyStorage.strategies[strategy].idleBalance = idleBalance;
            totalBaseBalance += _convertAssetToBase(strategy, idleBalance);
        }

        _getVaultStorage().totalAssets = totalBaseBalance;
    }

    function processAllocation(address[] calldata targets, uint256[] memory values, bytes[] calldata data)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        for (uint256 i = 0; i < targets.length; i++) {
            bool success;
            bytes memory returnData;

            // Determine the type of target and process accordingly
            if (_getAssetStorage().assets[targets[i]].active) {
                // Process asset approvals // QUESTION: Assumiung we only need approvals for assets
                if (data[i].length > 0 && data[i][0] == abi.encodeWithSignature("approve(address,uint256)")[0]) {
                    (success, returnData) = targets[i].call{value: values[i]}(data[i]);
                    if (!success) revert ProcessFailed(returnData);
                }
            } else if (_getStrategyStorage().strategies[targets[i]].active) {
                // Process strategy transactions
                (success, returnData) = targets[i].call{value: values[i]}(data[i]);
                if (!success) revert ProcessFailed(returnData);

                // Update idle balance for the strategy
                uint256 idleBalance = IERC20(targets[i]).balanceOf(address(this));
                _getStrategyStorage().strategies[targets[i]].idleBalance = idleBalance;
            } else {
                // Revert if the target is neither an active asset nor an active strategy
                revert BadStrategy(targets[i]);
            }
        }
    }

    //// INTERNAL ////

    function _convertToAssets(address asset_, uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        uint256 baseDenominatedShares = _convertAssetToBase(asset_, shares);
        return baseDenominatedShares.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    function _convertToShares(address asset_, uint256 assets_, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        uint256 convertedAssets = _convertAssetToBase(asset_, assets_);
        return convertedAssets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    function _convertAssetToBase(address asset_, uint256 amount) internal view returns (uint256) {
        uint256 rate = IRateProvider(_getVaultStorage().rateProvider).getRate(asset_);
        return amount.mulDiv(rate, 10 ** _getAssetStorage().assets[asset_].decimals, Math.Rounding.Floor);
    }

    function _convertBaseToAsset(address asset_, uint256 baseAmount) internal view returns (uint256) {
        uint256 rate = IRateProvider(_getVaultStorage().rateProvider).getRate(asset_);
        return baseAmount.mulDiv(10 ** _getAssetStorage().assets[asset_].decimals, rate, Math.Rounding.Floor);
    }

    /// @dev Being Multi asset, we need to add the asset param here to deposit the user's asset accordingly.
    function _deposit(address asset_, address caller, address receiver, uint256 assets, uint256 shares) internal {
        _getVaultStorage().totalAssets += assets;

        SafeERC20.safeTransferFrom(IERC20(asset_), caller, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    // QUESTION: How might we
    function _withdraw(address caller, address receiver, address owner, uint256 assets_, uint256 shares) internal {
        // reduce the totalAssets QUESTION: Should this go in the deposit function:
        _getVaultStorage().totalAssets -= assets_;

        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // Check if the contract has enough balance
        uint256 contractBalance = IERC20(asset()).balanceOf(address(this));
        if (contractBalance < assets_) {
            uint256 shortfall = assets_ - contractBalance;

            // pull base asset shortfall from the buffer strategy
            IStrategy(_getVaultStorage().bufferStrategy).withdraw(shortfall, address(this), address(this));
        }

        _burn(owner, shares);
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets_);

        emit Withdraw(caller, receiver, owner, assets_, shares);
    }

    function _decimalsOffset() internal pure returns (uint8) {
        return 0;
    }

    function _getVaultStorage() internal pure returns (VaultStorage storage $) {
        assembly {
            $.slot := 0x22cdba5640455d74cb7564fb236bbbbaf66b93a0cc1bd221f1ee2a6b2d0a2427
        }
    }

    function _getAssetStorage() internal pure returns (AssetStorage storage $) {
        assembly {
            $.slot := 0x2dd192a2474c87efcf5ffda906a4b4f8a678b0e41f9245666251cfed8041e680
        }
    }

    function _getStrategyStorage() internal pure returns (StrategyStorage storage $) {
        assembly {
            $.slot := 0x36e313fea70c5f83d23dd12fc41865566e392cbac4c21baf7972d39f7af1774d
        }
    }

    //// ADMIN ////

    function setRateProvider(address rateProvider_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (rateProvider_ == address(0)) revert ZeroAddress();
        _getVaultStorage().rateProvider = rateProvider_;
        emit SetRateProvider(rateProvider_);
    }

    function setBufferStrategy(address bufferStrategy_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bufferStrategy_ == address(0)) revert ZeroAddress();
        StrategyStorage storage strategyStorage = _getStrategyStorage();
        if (!strategyStorage.strategies[bufferStrategy_].active) revert InvalidStrategy();
        _getVaultStorage().bufferStrategy = bufferStrategy_;
        emit SetBufferStrategy(bufferStrategy_);
    }

    function addAsset(address asset_, uint8 decimals_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset_ == address(0)) revert ZeroAddress();

        AssetStorage storage assetStorage = _getAssetStorage();
        uint256 index = assetStorage.list.length;
        if (index > 0 && assetStorage.assets[asset_].index != 0) revert InvalidAsset();

        assetStorage.assets[asset_] = AssetParams({active: true, index: index, decimals: decimals_, idleBalance: 0});

        assetStorage.list.push(asset_);

        emit NewAsset(asset_, decimals_, index);
    }

    function toggleAsset(address asset_, bool active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        AssetStorage storage assetStorage = _getAssetStorage();
        if (assetStorage.assets[asset_].index == 0) revert InvalidAsset();
        assetStorage.assets[asset_].active = active;
        emit ToggleAsset(asset_, active);
    }

    function addStrategy(address strategy, uint8 decimals_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (strategy == address(0)) revert ZeroAddress();

        StrategyStorage storage strategyStorage = _getStrategyStorage();
        uint256 index = strategyStorage.list.length;

        if (index > 0 && strategyStorage.strategies[strategy].index != 0) {
            revert DuplicateStrategy();
        }

        strategyStorage.strategies[strategy] =
            StrategyParams({active: true, index: index, decimals: decimals_, idleBalance: 0});

        strategyStorage.list.push(strategy);

        emit NewStrategy(strategy, index);
    }

    function pause(bool paused_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        VaultStorage storage vaultStorage = _getVaultStorage();
        if (_getVaultStorage().rateProvider == address(0)) revert RateProviderNotSet();
        if (_getVaultStorage().bufferStrategy == address(0)) revert BufferNotSet();
        vaultStorage.paused = paused_;
        emit Pause(paused_);
    }

    // QUESTION: Start with Strategies or add them later
    // vault starts paused because the rate provider and assets / strategies haven't been set
    function initialize(address admin, string memory name, string memory symbol) external initializer {
        // Initialize the vault
        __ERC20_init(name, symbol);
        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        _getVaultStorage().paused = true;
    }

    constructor() {
        _disableInitializers();
    }
}
