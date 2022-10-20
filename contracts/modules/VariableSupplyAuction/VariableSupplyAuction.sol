// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.10;

import {ReentrancyGuard} from "@rari-capital/solmate/src/utils/ReentrancyGuard.sol";
import {ERC721Drop} from "./temp-MockERC721Drop.sol";

import {ERC721TransferHelper} from "../../transferHelpers/ERC721TransferHelper.sol";
import {FeePayoutSupportV1} from "../../common/FeePayoutSupport/FeePayoutSupportV1.sol";
import {ModuleNamingSupportV1} from "../../common/ModuleNamingSupport/ModuleNamingSupportV1.sol";

import {IVariableSupplyAuction} from "./IVariableSupplyAuction.sol";

/// @title Variable Supply Auction
/// @author neodaoist
/// @notice Module for variable supply, seller's choice, sealed bid auctions in ETH for ERC-721 tokens
contract VariableSupplyAuction is IVariableSupplyAuction, ReentrancyGuard, FeePayoutSupportV1, ModuleNamingSupportV1  {
    //

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _erc721TransferHelper,
        address _royaltyEngine,
        address _protocolFeeSettings,
        address _weth
    )
        FeePayoutSupportV1(_royaltyEngine, _protocolFeeSettings, _weth, ERC721TransferHelper(_erc721TransferHelper).ZMM().registrar())
        ModuleNamingSupportV1("Variable Supply Auction")
    {
        // erc721TransferHelper = ERC721TransferHelper(_erc721TransferHelper);
    }

    /*//////////////////////////////////////////////////////////////
                        AUCTION STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The metadata for a given auction
    /// @param seller The seller of this auction
    /// @param minimumViableRevenue The minimum revenue the seller needs to generate in this auction
    /// @param sellerFundsRecipient The address where funds are sent after the auction
    /// @param startTime The unix timestamp after which the first bid can be placed
    /// @param endOfBidPhase The unix timestamp until which bids can be placed
    /// @param endOfRevealPhase The unix timestamp until which placed bids can be revealed
    /// @param endOfSettlePhase The unix timestamp until which the seller can settle the auction (TODO clarify can vs. must)
    /// @param totalBalance The total balance of all sent ether for this auction
    /// @param settledRevenue The total revenue generated by the drop
    /// @param settledPricePoint The chosen price point for the drop
    /// @param settledEditionSize The resulting edition size for the drop
    struct Auction {
        address seller;
        uint96 minimumViableRevenue;
        address sellerFundsRecipient;
        uint32 startTime;
        uint32 endOfBidPhase;
        uint32 endOfRevealPhase;
        uint32 endOfSettlePhase;
        uint96 totalBalance;
        uint96 settledRevenue;
        uint96 settledPricePoint;
        uint16 settledEditionSize;
    }

    /// @notice A sealed bid
    /// @param commitmentHash The sha256 hash of the sealed bid amount concatenated with
    /// a salt string, both of which need to be included in the subsequent reveal bid tx
    /// @param bidderBalance The current bidder balance -- before auction has been settled,
    /// this is the total amount of ether included with their bid; after auction has been
    /// settled, this is the amount of ether available for bidder to claim. More specifically,
    /// if bidder was a winner, this is the included amount of ether less the settled
    /// price point; if bidder was not a winner, this is total amount of ether originally included.
    /// @param revealedBidAmount The revealed bid amount
    struct Bid {
        bytes32 commitmentHash;
        uint96 bidderBalance;
        uint96 revealedBidAmount;
    }

    /// @notice The auction for a given ERC-721 drop contract, if one exists
    /// (only one auction per token contract is allowed at one time)
    /// @dev ERC-721 token contract => Auction    
    mapping(address => Auction) public auctionForDrop;

    /// @notice The bids which have been placed in a given Auction
    /// @dev ERC-721 token contract => (bidder address => Bid)
    mapping(address => mapping(address => Bid)) public bidsForDrop;

    /// @notice The addresses who have placed and revealed a bid in a given auction
    /// @dev ERC-721 token contract => all bidders who have revealed their bid
    mapping(address => address[]) public revealedBiddersForDrop;

    /*//////////////////////////////////////////////////////////////
                        CREATE AUCTION
    //////////////////////////////////////////////////////////////*/

    // TODO add UML diagram

    /// @notice Emitted when an auction is created
    /// @param tokenContract The address of the ERC-721 drop contract
    /// @param auction The metadata of the created auction
    event AuctionCreated(address indexed tokenContract, Auction auction);

    /// @notice Creates a variable supply auction
    /// @dev A given ERC-721 drop contract can have only one live auction at any one time
    /// @param _tokenContract The address of the ERC-721 drop contract
    /// @param _minimumViableRevenue The minimum revenue the seller aims to generate in this auction --
    /// they can settle the auction below this value, but they cannot _not_ settle if the revenue
    /// generated by any price point + edition size combination would be at least this value
    /// @param _sellerFundsRecipient The address to send funds to once the auction is complete
    /// @param _startTime The time that users can begin placing bids
    /// @param _bidPhaseDuration The length of time of the bid phase in seconds
    /// @param _revealPhaseDuration The length of time of the reveal phase in seconds
    /// @param _settlePhaseDuration The length of time of the settle phase in seconds
    function createAuction(
        address _tokenContract,
        uint256 _minimumViableRevenue,
        address _sellerFundsRecipient,
        uint256 _startTime,
        uint256 _bidPhaseDuration,
        uint256 _revealPhaseDuration,
        uint256 _settlePhaseDuration
    ) external nonReentrant {
        // Ensure the drop does not already have a live auction
        require(auctionForDrop[_tokenContract].startTime == 0, "ONLY_ONE_LIVE_AUCTION_PER_DROP");

        // Ensure the funds recipient is specified
        require(_sellerFundsRecipient != address(0), "INVALID_FUNDS_RECIPIENT");

        // Get the auction's storage pointer
        Auction storage auction = auctionForDrop[_tokenContract];

        // Store the associated metadata
        auction.seller = msg.sender;
        auction.minimumViableRevenue = uint96(_minimumViableRevenue);
        auction.sellerFundsRecipient = _sellerFundsRecipient;
        auction.startTime = uint32(_startTime);
        auction.endOfBidPhase = uint32(_startTime + _bidPhaseDuration);
        auction.endOfRevealPhase = uint32(_startTime + _bidPhaseDuration + _revealPhaseDuration);
        auction.endOfSettlePhase = uint32(_startTime + _bidPhaseDuration + _revealPhaseDuration + _settlePhaseDuration);

        emit AuctionCreated(_tokenContract, auction);
    }

    /*//////////////////////////////////////////////////////////////
                        CANCEL AUCTION
    //////////////////////////////////////////////////////////////*/

    // TODO add UML

    /// @notice Emitted when an auction is canceled
    /// @param tokenContract The address of the ERC-721 drop contract
    /// @param auction The metadata of the canceled auction
    event AuctionCanceled(address indexed tokenContract, Auction auction);

    /// @notice Cancels the auction for a given drop
    /// @param _tokenContract The address of the ERC-721 drop contract
    function cancelAuction(address _tokenContract) external nonReentrant {
        // Get the auction for the specified drop
        Auction memory auction = auctionForDrop[_tokenContract];

        // Ensure that no bids have been placed in this auction yet
        require(auction.totalBalance == 0, "CANNOT_CANCEL_AUCTION_WITH_BIDS");        

        // Ensure the caller is the seller
        require(msg.sender == auction.seller, "ONLY_SELLER");

        emit AuctionCanceled(_tokenContract, auction);

        // Remove the auction from storage
        delete auctionForDrop[_tokenContract];
    }

    /*//////////////////////////////////////////////////////////////
                        PLACE BID
    //////////////////////////////////////////////////////////////*/

    // TODO add UML

    /// @notice Emitted when a bid is placed
    /// @param tokenContract The address of the ERC-721 drop contract
    /// @param bidder The address that placed a sealed bid
    /// @param auction The metadata of the auction
    event BidPlaced(address indexed tokenContract, address indexed bidder, Auction auction);

    /// @notice Places a bid in a variable supply auction
    /// @dev Note that the included ether amount must be greater than or equal to the sealed bid
    /// amount. This allows the bidder to obfuscate their true bid amount until the reveal phase.
    /// @param _tokenContract The address of the ERC-721 drop contract
    /// @param _commitmentHash The sha256 hash of the sealed bid amount concatenated with
    /// a salt string, both of which need to be included in the subsequent reveal bid tx
    function placeBid(address _tokenContract, bytes32 _commitmentHash) external payable nonReentrant {
        // Get the auction for the specified drop
        Auction storage auction = auctionForDrop[_tokenContract];

        // Ensure the auction exists
        require(auction.seller != address(0), "AUCTION_DOES_NOT_EXIST");

        // Ensure the auction is still in bid phase
        require(block.timestamp < auction.endOfBidPhase, "BIDS_ONLY_ALLOWED_DURING_BID_PHASE");

        // Ensure the bidder has not placed a bid in auction already
        require(bidsForDrop[_tokenContract][msg.sender].bidderBalance == 0, "ALREADY_PLACED_BID_IN_AUCTION");

        // Ensure the bid is valid and includes some ether
        require(msg.value > 0 ether, "VALID_BIDS_MUST_INCLUDE_ETHER");

        // Update the total balance for auction
        auction.totalBalance += uint96(msg.value);
        
        // Store the commitment hash and included ether amount
        bidsForDrop[_tokenContract][msg.sender] = Bid({
            commitmentHash: _commitmentHash,
            bidderBalance: uint96(msg.value),
            revealedBidAmount: 0
        });

        emit BidPlaced(_tokenContract, msg.sender, auction);
    }

    /*//////////////////////////////////////////////////////////////
                        REVEAL BID
    //////////////////////////////////////////////////////////////*/

    // TODO add UML

    /// @notice Emitted when a bid is revealed
    /// @param tokenContract The address of the ERC-721 drop contract
    /// @param bidder The address that placed a sealed bid
    /// @param bidAmount The revealed bid amount
    /// @param auction The metadata of the auction
    event BidRevealed(address indexed tokenContract, address indexed bidder, uint256 indexed bidAmount, Auction auction);

    /// @notice Reveals a previously placed bid
    /// @param _tokenContract The address of the ERC-721 drop contract
    /// @param _bidAmount The true bid amount
    /// @param _salt The string which was used, in combination with the true bid amount,
    /// to generate the commitment hash sent with the original placed bid tx
    function revealBid(address _tokenContract, uint256 _bidAmount, string calldata _salt) external nonReentrant {
        // Get the auction for the specified drop
        Auction storage auction = auctionForDrop[_tokenContract];

        // Ensure auction is in reveal phase
        require(block.timestamp >= auction.endOfBidPhase && block.timestamp < auction.endOfRevealPhase, "REVEALS_ONLY_ALLOWED_DURING_REVEAL_PHASE");

        // Get the bid for the specified bidder
        Bid storage bid = bidsForDrop[_tokenContract][msg.sender];

        // Ensure bidder placed bid in auction
        require(bid.bidderBalance > 0 ether, "NO_PLACED_BID_FOUND_FOR_ADDRESS");

        // Ensure revealed bid amount is not greater than sent ether
        require(_bidAmount <= bid.bidderBalance, "REVEALED_BID_CANNOT_BE_GREATER_THAN_SENT_ETHER");

        // Ensure revealed bid matches sealed bid
        require(keccak256(abi.encodePacked(_bidAmount, bytes(_salt))) == bid.commitmentHash, "REVEALED_BID_DOES_NOT_MATCH_SEALED_BID");

        // Store the bidder
        revealedBiddersForDrop[_tokenContract].push(msg.sender);

        // Store the revealed bid amount
        uint96 bidAmount = uint96(_bidAmount);
        bid.revealedBidAmount = bidAmount;

        emit BidRevealed(_tokenContract, msg.sender, _bidAmount, auction);
    }

    /*//////////////////////////////////////////////////////////////
                        SETTLE AUCTION
    //////////////////////////////////////////////////////////////*/

    // TODO add UML

    // TODO add view function for price point + edition size options based on revealed bids

    /// @notice Emitted when an auction is settled
    /// @param tokenContract The address of the ERC-721 drop contract
    /// @param auction The metadata of the created auction
    event AuctionSettled(address indexed tokenContract, Auction auction);

    function settleAuction(address _tokenContract, uint96 _settlePricePoint) external nonReentrant {
        // TODO checks

        // TODO gas optimizations

        // Get the auction
        Auction storage auction = auctionForDrop[_tokenContract];

        // Get the bidders who revealed in this auction
        address[] storage bidders = revealedBiddersForDrop[_tokenContract];

        // Get the balances for this auction
        mapping(address => Bid) storage bids = bidsForDrop[_tokenContract];

        // Loop through bids to determine winners and edition size
        // TODO document pragmatic max edition size / winning bidders
        address[] memory winningBidders = new address[](1000);      
        uint16 editionSize;
        for (uint256 i = 0; i < bidders.length; i++) {
            // Cache the bidder
            address bidder = bidders[i];

            // Check if bid qualifies
            if (bidsForDrop[_tokenContract][bidder].revealedBidAmount >= _settlePricePoint) {
                // Mark winning bidder and increment edition size
                winningBidders[editionSize++] = bidder;

                // Update final revenue
                auction.settledRevenue += _settlePricePoint;

                // Update their balance
                bids[bidder].bidderBalance -= _settlePricePoint;
            }
        }

        // Store the current total balance and final auction details
        auction.totalBalance -= auction.settledRevenue;
        auction.settledPricePoint = _settlePricePoint;
        auction.settledEditionSize = editionSize;

        // Update edition size
        ERC721Drop(_tokenContract).setEditionSize(uint64(winningBidders.length));
        
        // Mint NFTs to winning bidders
        ERC721Drop(_tokenContract).adminMintAirdrop(winningBidders);

        // Transfer the auction revenue to the funds recipient
        _handleOutgoingTransfer(auction.sellerFundsRecipient, auction.settledRevenue, address(0), 50_000);        

        emit AuctionSettled(_tokenContract, auction);
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIM REFUND
    //////////////////////////////////////////////////////////////*/

    // TODO 

}
