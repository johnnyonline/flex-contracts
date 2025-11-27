// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IAuction {

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The address that will receive the funds in the auction.
    function receiver() external view returns (address);

    /// @notice The minimum price for the auction, scaled to 1e18.
    function minimumPrice() external view returns (uint256);

    /// @notice The amount to start the auction at.
    function startingPrice() external view returns (uint256);

    /// @notice The time period for each price step in seconds.
    function stepDuration() external view returns (uint256);

    /// @notice The decay rate per step in basis points (e.g., 50 for 0.5% decrease per step).
    function stepDecayRate() external view returns (uint256);

    /// @notice Array of all the enabled auction for this contract.
    function enabledAuctions(
        uint256
    ) external view returns (address);

    /*//////////////////////////////////////////////////////////////
                         VIEW METHODS
    //////////////////////////////////////////////////////////////*/

    function version() external pure returns (string memory);

    /**
     * @notice Get the address of this auctions want token.
     * @return . The want token.
     */
    function want() external view returns (address);

    function auctionLength() external view returns (uint256);

    /**
     * @notice Get the available amount for the auction.
     * @param _from The address of the token to be auctioned.
     * @return . The available amount for the auction.
     */
    function available(
        address _from
    ) external view returns (uint256);

    /**
     * @notice Get the kicked timestamp for the auction.
     * @param _from The address of the token to be auctioned.
     * @return . The kicked timestamp for the auction.
     */
    function kicked(
        address _from
    ) external view returns (uint256);

    /**
     * @notice Check if the auction is active.
     * @param _from The address of the token to be auctioned.
     * @return . Whether the auction is active.
     */
    function isActive(
        address _from
    ) external view returns (bool);

    /**
     * @notice Get all the enabled auctions.
     */
    function getAllEnabledAuctions() external view returns (address[] memory);

    /**
     * @notice Get the pending amount available for the next auction.
     * @dev Defaults to the auctions balance of the from token if no hook.
     * @param _from The address of the token to be auctioned.
     * @return uint256 The amount that can be kicked into the auction.
     */
    function kickable(
        address _from
    ) external view returns (uint256);

    /**
     * @notice Gets the amount of `want` needed to buy the available amount of `from`.
     * @param _from The address of the token to be auctioned.
     * @return . The amount of `want` needed to fulfill the take amount.
     */
    function getAmountNeeded(
        address _from
    ) external view returns (uint256);

    /**
     * @notice Gets the amount of `want` needed to buy a specific amount of `from`.
     * @param _from The address of the token to be auctioned.
     * @param _amountToTake The amount of `from` to take in the auction.
     * @return . The amount of `want` needed to fulfill the take amount.
     */
    function getAmountNeeded(
        address _from,
        uint256 _amountToTake
    ) external view returns (uint256);

    /**
     * @notice Gets the amount of `want` needed to buy a specific amount of `from` at a specific timestamp.
     * @param _from The address of the token to be auctioned.
     * @param _amountToTake The amount `from` to take in the auction.
     * @param _timestamp The specific timestamp for calculating the amount needed.
     * @return . The amount of `want` needed to fulfill the take amount.
     */
    function getAmountNeeded(
        address _from,
        uint256 _amountToTake,
        uint256 _timestamp
    ) external view returns (uint256);

    /**
     * @notice Gets the price of the auction at the current timestamp.
     * @param _from The address of the token to be auctioned.
     * @return . The price of the auction.
     */
    function price(
        address _from
    ) external view returns (uint256);

    /**
     * @notice Gets the price of the auction at a specific timestamp.
     * @param _from The address of the token to be auctioned.
     * @param _timestamp The specific timestamp for calculating the price.
     * @return . The price of the auction.
     */
    function price(
        address _from,
        uint256 _timestamp
    ) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            SETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Enables a new auction.
     * @param _from The address of the token to be auctioned.
     */
    function enable(
        address _from
    ) external;

    /**
     * @notice Disables an existing auction.
     * @dev Only callable by governance.
     * @param _from The address of the token being sold.
     */
    function disable(
        address _from
    ) external;

    /**
     * @notice Disables an existing auction.
     * @dev Only callable by governance.
     * @param _from The address of the token being sold.
     * @param _index The index the auctionId is at in the array.
     */
    function disable(
        address _from,
        uint256 _index
    ) external;

    /**
     * @notice Check if there is any active auction.
     * @return bool Whether there is an active auction.
     */
    function isAnActiveAuction() external view returns (bool);

    /**
     * @notice Sets the receiver address for the auction funds.
     * @param _receiver The new receiver address.
     */
    function setReceiver(
        address _receiver
    ) external;

    /**
     * @notice Sets the minimum price for the auction.
     * @dev If the price per auction goes below this, the auction is considered inactive.
     * @param _minimumPrice The new minimum price for the auction.
     */
    function setMinimumPrice(
        uint256 _minimumPrice
    ) external;

    /**
     * @notice Sets the starting price for the auction.
     * @param _startingPrice The new starting price for the auction.
     */
    function setStartingPrice(
        uint256 _startingPrice
    ) external;

    /**
     * @notice Sets the step decay rate for the auction.
     * @dev The decay rate is in basis points (e.g., 50 for 0.5% decay per step).
     * @param _stepDecayRate The new decay rate per step in basis points (max 10000 = 100%).
     */
    function setStepDecayRate(
        uint256 _stepDecayRate
    ) external;

    /**
     * @notice Sets the step duration for the auction.
     * @param _stepDuration The new step duration in seconds.
     */
    function setStepDuration(
        uint256 _stepDuration
    ) external;

    /*//////////////////////////////////////////////////////////////
                      PARTICIPATE IN AUCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Kicks off an auction, updating its status and making funds available for bidding.
     * @param _from The address of the token to be auctioned.
     * @return _available The available amount for bidding on in the auction.
     */
    function kick(
        address _from
    ) external returns (uint256 _available);

    /**
     * @notice Take the token being sold in a live auction.
     * @dev Defaults to taking the full amount and sending to the msg sender.
     * @param _from The address of the token to be auctioned.
     * @return . The amount of fromToken taken in the auction.
     */
    function take(
        address _from
    ) external returns (uint256);

    /**
     * @notice Take the token being sold in a live auction with a specified maximum amount.
     * @dev Will send the funds to the msg sender.
     * @param _from The address of the token to be auctioned.
     * @param _maxAmount The maximum amount of fromToken to take in the auction.
     * @return . The amount of fromToken taken in the auction.
     */
    function take(
        address _from,
        uint256 _maxAmount
    ) external returns (uint256);

    /**
     * @notice Take the token being sold in a live auction.
     * @param _from The address of the token to be auctioned.
     * @param _maxAmount The maximum amount of fromToken to take in the auction.
     * @param _receiver The address that will receive the fromToken.
     * @return _amountTaken The amount of fromToken taken in the auction.
     */
    function take(
        address _from,
        uint256 _maxAmount,
        address _receiver
    ) external returns (uint256);

    /**
     * @notice Take the token being sold in a live auction.
     * @param _from The address of the token to be auctioned.
     * @param _maxAmount The maximum amount of fromToken to take in the auction.
     * @param _receiver The address that will receive the fromToken.
     * @param _data The data signify the callback should be used and sent with it.
     * @return _amountTaken The amount of fromToken taken in the auction.
     */
    function take(
        address _from,
        uint256 _maxAmount,
        address _receiver,
        bytes calldata _data
    ) external returns (uint256);

    /// @dev Validates a COW order signature.
    function isValidSignature(
        bytes32 _hash,
        bytes calldata signature
    ) external view returns (bytes4);

    /**
     * @notice Forces a kick for the auction.
     * @dev Only callable by governance.
     * @param _from The address of the token to be auctioned.
     */
    function forceKick(
        address _from
    ) external;

    /**
     * @notice Allows the auction to be stopped if the full amount is taken.
     * @param _from The address of the token to be auctioned.
     */
    function settle(
        address _from
    ) external;

    function sweep(
        address _token
    ) external;

}
