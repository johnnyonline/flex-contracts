// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ILeverageZapper} from "../interfaces/ILeverageZapper.sol";

import {IPriceOracle} from "../../test/interfaces/IPriceOracle.sol";
import {ITroveManager} from "../../test/interfaces/ITroveManager.sol";

import "forge-std/Script.sol";

abstract contract BaseZapperScript is Script {

    // ============================================================================================
    // Parameters - tweak before running
    // ============================================================================================

    // Market
    ITroveManager public constant TROVE_MANAGER = ITroveManager(0xd82DB9893751E9C90E2a6C3bE31183048E8E2e49);

    // Periphery (prod from script/README.md)
    ILeverageZapper public constant LEVERAGE_ZAPPER = ILeverageZapper(0xbF3E996821D43ac3b6069Ae74Efa101ffc6137E0);

    // Common math / slippage
    uint256 public constant SLIPPAGE_BPS = 1; // 0.01%
    uint256 public constant BPS = 10_000;
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;

    // ============================================================================================
    // Storage shared by all zapper scripts
    // ============================================================================================

    address internal _user;
    address internal _collateralToken;
    address internal _borrowToken;
    uint256 internal _price;
    uint256 internal _collDec;
    uint256 internal _borrowDec;
    string internal _collSym;
    string internal _borrowSym;
    uint256 internal _borrowPerColl;
    uint256 internal _maxLtvBps;
    ITroveManager.Trove internal _trove;
    address internal _swapRouter;
    bytes internal _swapData;

    // ============================================================================================
    // Helpers
    // ============================================================================================

    /// @dev Reads BORROWER_PRIVATE_KEY env var, sets `_user`, and returns the pk.
    function _loadUser() internal returns (uint256 _pk) {
        _pk = vm.envUint("BORROWER_PRIVATE_KEY");
        _user = vm.addr(_pk);
        console.log("User:       %s", _user);
    }

    /// @dev Populates the market-state storage vars from the trove manager.
    function _loadMarket() internal {
        _collateralToken = TROVE_MANAGER.collateral_token();
        _borrowToken = TROVE_MANAGER.borrow_token();
        _price = IPriceOracle(TROVE_MANAGER.price_oracle()).get_price();

        _collDec = IERC20Metadata(_collateralToken).decimals();
        _borrowDec = IERC20Metadata(_borrowToken).decimals();
        _collSym = IERC20Metadata(_collateralToken).symbol();
        _borrowSym = IERC20Metadata(_borrowToken).symbol();

        _borrowPerColl = (10 ** _collDec) * _price / ORACLE_PRICE_SCALE;
        _maxLtvBps = BPS * 100 / (TROVE_MANAGER.minimum_collateral_ratio() / TROVE_MANAGER.one_pct());
    }

    /// @dev Approves the LeverageZapper as a Trove Manager operator if it isn't already.
    function _ensureZapperApproved() internal {
        if (!TROVE_MANAGER.approved(_user, address(LEVERAGE_ZAPPER))) {
            console.log("Approving LeverageZapper as a Trove Manager operator...");
            TROVE_MANAGER.approve(address(LEVERAGE_ZAPPER), true);
        }
    }

    /// @dev Format a bps value as `"XX.YY%"`.
    function _fmtPct(
        uint256 _bps
    ) internal pure returns (string memory) {
        uint256 _whole = _bps / 100;
        uint256 _frac = _bps % 100;
        string memory _fracStr = vm.toString(_frac);
        if (bytes(_fracStr).length < 2) _fracStr = string.concat("0", _fracStr);
        return string.concat(vm.toString(_whole), ".", _fracStr, "%");
    }

    /// @dev Format a raw token amount as `"X.YYYYYY SYM"` using the token's decimals.
    function _format(
        uint256 _amount,
        uint256 _decimals,
        string memory _symbol
    ) internal pure returns (string memory) {
        uint256 _scale = 10 ** _decimals;
        uint256 _whole = _amount / _scale;
        uint256 _frac = _amount % _scale;

        // Pad the fractional part with leading zeros to `_decimals` digits
        string memory _fracStr = vm.toString(_frac);
        while (bytes(_fracStr).length < _decimals) _fracStr = string.concat("0", _fracStr);

        return string.concat(vm.toString(_whole), ".", _fracStr, " ", _symbol);
    }

    /// @dev Calls `script/get_enso_swap.sh` which outputs `abi.encodePacked(router, data)`.
    function _getEnsoSwapData(
        uint256 _chainId,
        address _inputToken,
        address _outputToken,
        uint256 _amount,
        address _sender
    ) internal returns (address _router, bytes memory _data) {
        string[] memory _cmd = new string[](7);
        _cmd[0] = "bash";
        _cmd[1] = "script/get_enso_swap.sh";
        _cmd[2] = vm.toString(_chainId);
        _cmd[3] = vm.toString(_inputToken);
        _cmd[4] = vm.toString(_outputToken);
        _cmd[5] = vm.toString(_amount);
        _cmd[6] = vm.toString(_sender);
        bytes memory _raw = vm.ffi(_cmd);

        require(_raw.length > 20, "enso: empty response");

        // First 20 bytes = router, rest = calldata
        assembly {
            _router := shr(96, mload(add(_raw, 32)))
            let dataLen := sub(mload(_raw), 20)
            _data := mload(0x40)
            mstore(_data, dataLen)
            mstore(0x40, add(add(_data, 32), dataLen))
        }
        for (uint256 i = 0; i < _data.length; i++) {
            _data[i] = _raw[i + 20];
        }
    }

}
