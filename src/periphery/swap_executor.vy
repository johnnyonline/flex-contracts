# @version 0.4.3

"""
@title Swap Executor
@license GNU AGPLv3
@author Flex
@notice Executes swaps on behalf of the Leverage Zapper via DEX aggregator routers
"""

from ethereum.ercs import IERC20

# ============================================================================================
# Constants
# ============================================================================================


# Max swap calldata size
_MAX_SWAP_DATA_SIZE: constant(uint256) = 10 ** 4


# ============================================================================================
# Swap
# ============================================================================================


@external
def swap(router: address, data: Bytes[_MAX_SWAP_DATA_SIZE], token_in: address, token_out: address):
    """
    @notice Execute a swap and transfer the output tokens back to the caller
    @dev Caller must transfer input tokens to this contract before calling
    @dev Caller should encode slippage protection in the router calldata
    @param router The DEX aggregator router address
    @param data The swap calldata
    @param token_in The input token
    @param token_out The output token
    """
    # Get the input tokens amount
    amount_in: uint256 = staticcall IERC20(token_in).balanceOf(self)

    # Approve the router to spend input tokens
    assert extcall IERC20(token_in).approve(router, amount_in, default_return_value=True)

    # Execute the swap
    raw_call(router, data)

    # Make sure our approval is always back to 0
    assert extcall IERC20(token_in).approve(router, 0, default_return_value=True)

    # Send all output tokens back to the caller
    amount_out: uint256 = staticcall IERC20(token_out).balanceOf(self)
    if amount_out > 0:
        assert extcall IERC20(token_out).transfer(msg.sender, amount_out, default_return_value=True)
