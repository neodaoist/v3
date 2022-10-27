// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.10;

/// @title IVariableSupplyAuction
/// @author neodaoist
/// @notice Interface for Variable Supply Auction
interface IVariableSupplyAuction {
    //

    // TODO x add NatSpec here also
    ///
    function createAuction(
        address _tokenContract,
        uint256 _minimumRevenue,
        address _sellerFundsRecipient,
        uint256 _startTime,
        uint256 _bidPhaseDuration,
        uint256 _revealPhaseDuration,
        uint256 _settlePhaseDuration
    ) external;

    ///
    function cancelAuction(address _tokenContract) external;

    ///
    function placeBid(address _tokenContract, bytes32 _commitmentHash) external payable;

    ///
    function revealBid(address _tokenContract, uint256 _bidAmount, string calldata _salt) external;

    ///
    function calculateSettleOptions(address _tokenContract) external returns (uint96[] memory, uint16[] memory, uint96[] memory);

    ///
    function settleAuction(address _tokenContract, uint96 _settlePricePoint) external;

    ///
    function checkAvailableRefund(address _tokenContract) external view returns (uint96);

    ///
    function claimRefund(address _tokenContract) external;
}
