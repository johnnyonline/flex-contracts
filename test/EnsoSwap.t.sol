// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract EnsoSwapTests is Base {

    uint256 constant MAX_SLIPPAGE_BPS = 500; // 5%
    uint256 constant BPS = 10_000;

    function setUp() public override {
        isLatestBlock = true;
        Base.setUp();
    }

    function test_ensoSwap_collateralToBorrow() public {
        uint256 _amount = 1 * COLLATERAL_TOKEN_PRECISION;
        address _swapper = address(this);

        (address _router, bytes memory _swapData) = _getEnsoSwapData(1, address(collateralToken), address(borrowToken), _amount, _swapper);

        airdrop(address(collateralToken), _swapper, _amount);
        collateralToken.approve(_router, _amount);

        uint256 _borrowBefore = borrowToken.balanceOf(_swapper);
        (bool _success,) = _router.call(_swapData);
        require(_success, "swap failed");

        uint256 _received = borrowToken.balanceOf(_swapper) - _borrowBefore;
        uint256 _expectedOut = _amount * priceOracle.get_price() / ORACLE_PRICE_SCALE;
        assertGt(_received, _expectedOut * (BPS - MAX_SLIPPAGE_BPS) / BPS, "slippage too high");
    }

    function test_ensoSwap_borrowToCollateral() public {
        uint256 _amount = 1000 * BORROW_TOKEN_PRECISION;
        address _swapper = address(this);

        (address _router, bytes memory _swapData) = _getEnsoSwapData(1, address(borrowToken), address(collateralToken), _amount, _swapper);

        airdrop(address(borrowToken), _swapper, _amount);
        borrowToken.approve(_router, _amount);

        uint256 _collateralBefore = collateralToken.balanceOf(_swapper);
        (bool _success,) = _router.call(_swapData);
        require(_success, "swap failed");

        uint256 _received = collateralToken.balanceOf(_swapper) - _collateralBefore;
        uint256 _expectedOut = _amount * ORACLE_PRICE_SCALE / priceOracle.get_price();
        assertGt(_received, _expectedOut * (BPS - MAX_SLIPPAGE_BPS) / BPS, "slippage too high");
    }

    /// @dev Returns (router, calldata) from the Enso API response.
    ///      The shell script outputs abi.encodePacked(to, data) — first 20 bytes are the router address.
    function _getEnsoSwapData(
        uint256 chainId,
        address inputToken,
        address outputToken,
        uint256 amount,
        address sender
    ) internal returns (address router, bytes memory data) {
        string[] memory cmd = new string[](7);
        cmd[0] = "bash";
        cmd[1] = "script/get_enso_swap.sh";
        cmd[2] = vm.toString(chainId);
        cmd[3] = vm.toString(inputToken);
        cmd[4] = vm.toString(outputToken);
        cmd[5] = vm.toString(amount);
        cmd[6] = vm.toString(sender);
        bytes memory _raw = vm.ffi(cmd);

        // First 20 bytes = router address, rest = calldata
        assembly {
            router := shr(96, mload(add(_raw, 32)))
            let dataLen := sub(mload(_raw), 20)
            data := mload(0x40)
            mstore(data, dataLen)
            mstore(0x40, add(add(data, 32), dataLen))
        }
        // Copy calldata bytes (after the 20-byte address)
        for (uint256 i = 0; i < data.length; i++) {
            data[i] = _raw[i + 20];
        }
    }

}
