// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.10;

import {ReentrancyGuard} from "@rari-capital/solmate/src/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721TransferHelper} from "../../../transferHelpers/ERC721TransferHelper.sol";
import {UniversalExchangeEventV1} from "../../../common/UniversalExchangeEvent/V1/UniversalExchangeEventV1.sol";
import {OutgoingTransferSupportV1} from "../../../common/OutgoingTransferSupport/V1/OutgoingTransferSupportV1.sol";
import {IncomingTransferSupportV1} from "../../../common/IncomingTransferSupport/V1/IncomingTransferSupportV1.sol";
import {FeePayoutSupportV1} from "../../../common/FeePayoutSupport/FeePayoutSupportV1.sol";
import {ModuleNamingSupportV1} from "../../../common/ModuleNamingSupport/ModuleNamingSupportV1.sol";

/// @title Reserve Auction V1
/// @author tbtstl <t@zora.co>
/// @notice This contract allows users to list and bid on ERC-721 tokens with timed reserve auctions
contract ReserveAuctionV1 is ReentrancyGuard, UniversalExchangeEventV1, IncomingTransferSupportV1, FeePayoutSupportV1, ModuleNamingSupportV1 {
    /// @dev The indicator to pass all remaining gas when paying out royalties
    uint256 private constant USE_ALL_GAS_FLAG = 0;
    /// @notice The minimum amount of time left in an auction after a new bid is created
    uint256 constant TIME_BUFFER = 15 minutes;
    /// @notice The minimum percentage difference between the last bid amount and the current bid.
    uint8 constant MIN_BID_INCREMENT_PERCENTAGE = 10;

    /// @notice The ZORA ERC-721 Transfer Helper
    ERC721TransferHelper public immutable erc721TransferHelper;

    /// @notice A mapping of NFTs to their respective auction ID
    /// @dev ERC-721 token address => ERC-721 token ID => auction ID
    mapping(address => mapping(uint256 => Auction)) public auctionForNFT;

    /// @notice The metadata of an auction
    /// @param seller The address that should receive the funds once the NFT is sold.
    /// @param auctionCurrency The address of the ERC-20 currency (0x0 for ETH) to run the auction with.
    /// @param sellerFundsRecipient The address of the recipient of the auction's highest bid
    /// @param bidder The address of the current highest bid
    /// @param finder The address of the current bid's finder
    /// @param findersFeeBps The sale bps to send to the winning bid finder
    /// @param amount The current highest bid amount
    /// @param duration The length of time to run the auction for, after the first bid was made
    /// @param startTime The time of the auction start
    /// @param firstBidTime The time of the first bid
    /// @param reservePrice The minimum price of the first bid
    struct Auction {
        address seller;
        address auctionCurrency;
        address sellerFundsRecipient;
        address bidder;
        address finder;
        uint16 findersFeeBps;
        uint256 amount;
        uint256 duration;
        uint256 startTime;
        uint256 firstBidTime;
        uint256 reservePrice;
    }

    /// @notice Emitted when an auction is created
    /// @param tokenContract The ERC-721 token address of the created auction
    /// @param tokenId The ERC-721 token ID of the created auction
    /// @param auction The metadata of the created auction
    event AuctionCreated(address indexed tokenContract, uint256 indexed tokenId, Auction auction);

    /// @notice Emitted when the reserve price of an auction is updated
    /// @param tokenContract The ERC-721 token address of the updated auction
    /// @param tokenId The ERC-721 token ID of the updated auction
    /// @param reservePrice The updated reserve price of the auction
    /// @param auction The metadata of the updated auction
    event AuctionReservePriceUpdated(address indexed tokenContract, uint256 indexed tokenId, uint256 indexed reservePrice, Auction auction);

    /// @notice Emitted when a bid is placed on an auction
    /// @param tokenContract The ERC-721 token address of the auction
    /// @param tokenId The ERC-721 token ID of the auction
    /// @param amount The amount bid on the auction
    /// @param bidder The address of the bidder
    /// @param firstBid Whether the bid kicked off the auction
    /// @param auction The metadata of the updated auction
    event AuctionBid(address indexed tokenContract, uint256 indexed tokenId, uint256 indexed amount, address bidder, bool firstBid, Auction auction);

    /// @notice Emitted when the duration of an auction is extended
    /// @param tokenContract The ERC-721 token address of the auction
    /// @param tokenId The ERC-721 token ID of the auction
    /// @param duration The updated duration of the auction
    /// @param auction The metadata of the extended auction
    event AuctionDurationExtended(address indexed tokenContract, uint256 indexed tokenId, uint256 indexed duration, Auction auction);

    /// @notice Emitted when an auction has ended
    /// @param tokenContract The ERC-721 token address of the auction
    /// @param tokenId The ERC-721 token ID of the auction
    /// @param winner The address of the winner bidder
    /// @param finder The address of the winning bid referrer
    /// @param auction The metadata of the ended auction
    event AuctionEnded(address indexed tokenContract, uint256 indexed tokenId, address indexed winner, address finder, Auction auction);

    /// @notice Emitted when an auction is canceled
    /// @param tokenContract The ERC-721 token address of the canceled auction
    /// @param tokenId The ERC-721 token ID of the canceled auction
    /// @param auction The metadata of the canceled auction
    event AuctionCanceled(address indexed tokenContract, uint256 indexed tokenId, Auction auction);

    /// @param _erc20TransferHelper The ZORA ERC-20 Transfer Helper address
    /// @param _erc721TransferHelper The ZORA ERC-721 Transfer Helper address
    /// @param _royaltyEngine The Manifold Royalty Engine address
    /// @param _protocolFeeSettings The ZoraProtocolFeeSettingsV1 address
    /// @param _wethAddress The WETH token address
    constructor(
        address _erc20TransferHelper,
        address _erc721TransferHelper,
        address _royaltyEngine,
        address _protocolFeeSettings,
        address _wethAddress
    )
        IncomingTransferSupportV1(_erc20TransferHelper)
        FeePayoutSupportV1(_royaltyEngine, _protocolFeeSettings, _wethAddress, ERC721TransferHelper(_erc721TransferHelper).ZMM().registrar())
        ModuleNamingSupportV1("Reserve Auction: v1.0")
    {
        erc721TransferHelper = ERC721TransferHelper(_erc721TransferHelper);
    }

    /// @notice Creates an auction for a given NFT
    /// @param _tokenContract The address of the ERC-721 token
    /// @param _tokenId The ID of the ERC-721 token being auctioned for sale
    /// @param _duration The amount of time the auction should run for after the initial bid is placed
    /// @param _reservePrice The minimum bid amount to start the auction
    /// @param _sellerFundsRecipient The address to send funds to once the token is sold
    /// @param _findersFeeBps The percentage of the sale amount to be sent to the referrer of the sale
    /// @param _auctionCurrency The address of the ERC-20 token to accept bids in, or address(0) for ETH
    /// @param _startTime The time to start the auction
    function createAuction(
        address _tokenContract,
        uint256 _tokenId,
        uint256 _duration,
        uint256 _reservePrice,
        address _sellerFundsRecipient,
        uint16 _findersFeeBps,
        address _auctionCurrency,
        uint256 _startTime
    ) external nonReentrant {
        address tokenOwner = IERC721(_tokenContract).ownerOf(_tokenId);
        require(
            msg.sender == tokenOwner || IERC721(_tokenContract).isApprovedForAll(tokenOwner, msg.sender),
            "createAuction must be token owner or operator"
        );
        require(erc721TransferHelper.isModuleApproved(msg.sender), "createAuction must approve ReserveAuctionV1 module");
        require(
            IERC721(_tokenContract).isApprovedForAll(tokenOwner, address(erc721TransferHelper)),
            "createAuction must approve ERC721TransferHelper as operator"
        );
        require(_findersFeeBps <= 10000, "createAuction _findersFeeBps must be less than or equal to 10000");
        require(_sellerFundsRecipient != address(0), "createAuction must specify _sellerFundsRecipient");
        require(_startTime == 0 || _startTime > block.timestamp, "createAuction _startTime must be 0 or future block");

        if (auctionForNFT[_tokenContract][_tokenId].seller != address(0)) {
            _cancelAuction(_tokenContract, _tokenId);
        }
        if (_startTime == 0) {
            _startTime = block.timestamp;
        }

        auctionForNFT[_tokenContract][_tokenId] = Auction({
            seller: tokenOwner,
            auctionCurrency: _auctionCurrency,
            sellerFundsRecipient: _sellerFundsRecipient,
            bidder: address(0),
            finder: address(0),
            findersFeeBps: _findersFeeBps,
            amount: 0,
            duration: _duration,
            startTime: _startTime,
            firstBidTime: 0,
            reservePrice: _reservePrice
        });

        emit AuctionCreated(_tokenContract, _tokenId, auctionForNFT[_tokenContract][_tokenId]);
    }

    /// @notice Update the reserve price for a given auction
    /// @param _tokenContract The address of the ERC-721 token
    /// @param _tokenId The ID of the ERC-721 token
    /// @param _reservePrice The new reserve price for the auction
    function setAuctionReservePrice(
        address _tokenContract,
        uint256 _tokenId,
        uint256 _reservePrice
    ) external {
        Auction storage auction = auctionForNFT[_tokenContract][_tokenId];

        require(msg.sender == auction.seller, "setAuctionReservePrice must be seller");
        require(auction.firstBidTime == 0, "setAuctionReservePrice auction has already started");

        auction.reservePrice = _reservePrice;

        emit AuctionReservePriceUpdated(_tokenContract, _tokenId, _reservePrice, auction);
    }

    /// @notice Places a bid on the auction, holding the bids in escrow and refunding any previous bids
    /// @param _tokenContract The address of the ERC-721 token
    /// @param _tokenId The ID of the ERC-721 token
    /// @param _amount The bid amount to be transferred
    /// @param _finder The address of the referrer for this bid
    function createBid(
        address _tokenContract,
        uint256 _tokenId,
        uint256 _amount,
        address _finder
    ) external payable nonReentrant {
        Auction storage auction = auctionForNFT[_tokenContract][_tokenId];

        require(auction.seller != address(0), "createBid auction doesn't exist");
        require(block.timestamp >= auction.startTime, "createBid auction hasn't started");
        require(auction.firstBidTime == 0 || block.timestamp < (auction.firstBidTime + auction.duration), "createBid auction expired");
        require(_amount >= auction.reservePrice, "createBid must send at least reservePrice");
        require(
            _amount >= (auction.amount + ((auction.amount * MIN_BID_INCREMENT_PERCENTAGE) / 100)),
            "createBid must send more than 10% of last bid amount"
        );

        // If first bid --
        bool firstBid;
        if (auction.firstBidTime == 0) {
            // Store time of bid
            auction.firstBidTime = block.timestamp;
            firstBid = true;
            // Transfer NFT into escrow
            erc721TransferHelper.transferFrom(_tokenContract, auction.seller, address(this), _tokenId);

            // Else refund previous bidder
        } else {
            _handleOutgoingTransfer(auction.bidder, auction.amount, auction.auctionCurrency, USE_ALL_GAS_FLAG);
        }

        // Ensure incoming bid payment is valid and take custody
        _handleIncomingTransfer(_amount, auction.auctionCurrency);

        auction.amount = _amount;
        auction.bidder = msg.sender;
        auction.finder = _finder;

        emit AuctionBid(_tokenContract, _tokenId, _amount, msg.sender, firstBid, auction);

        // If a bid is placed within 15 minutes of the auction ending --
        uint256 auctionTimeRemaining = auction.firstBidTime + auction.duration - block.timestamp;
        if (auctionTimeRemaining < TIME_BUFFER) {
            // Extend the auction by 15 minutes from the time of bid
            auction.duration += (TIME_BUFFER - auctionTimeRemaining);
            emit AuctionDurationExtended(_tokenContract, _tokenId, auction.duration, auction);
        }
    }

    /// @notice Ends an auction, pays out respective parties and transfers the NFT to the winning bidder
    /// @param _tokenContract The address of the ERC-721 token
    /// @param _tokenId The ID of the ERC-721 token
    function settleAuction(address _tokenContract, uint256 _tokenId) external nonReentrant {
        Auction storage auction = auctionForNFT[_tokenContract][_tokenId];

        require(auction.seller != address(0), "settleAuction auction doesn't exist");
        require(auction.firstBidTime != 0, "settleAuction auction hasn't begun");
        require(block.timestamp >= (auction.firstBidTime + auction.duration), "settleAuction auction hasn't completed");

        // Payout respective parties, ensuring royalties are honored
        (uint256 remainingProfit, ) = _handleRoyaltyPayout(_tokenContract, _tokenId, auction.amount, auction.auctionCurrency, USE_ALL_GAS_FLAG);

        // Payout optional protocol fee
        remainingProfit = _handleProtocolFeePayout(remainingProfit, auction.auctionCurrency);

        // Payout optional finders fee
        if (auction.finder != address(0)) {
            uint256 finderFee = (remainingProfit * auction.findersFeeBps) / 10000;
            _handleOutgoingTransfer(auction.finder, finderFee, auction.auctionCurrency, USE_ALL_GAS_FLAG);

            remainingProfit -= finderFee;
        }

        // Transfer remaining funds to seller
        _handleOutgoingTransfer(auction.sellerFundsRecipient, remainingProfit, auction.auctionCurrency, USE_ALL_GAS_FLAG);

        // Transfer NFT to winning bidder
        IERC721(_tokenContract).transferFrom(address(this), auction.bidder, _tokenId);

        ExchangeDetails memory userAExchangeDetails = ExchangeDetails({tokenContract: _tokenContract, tokenId: _tokenId, amount: 1});
        ExchangeDetails memory userBExchangeDetails = ExchangeDetails({tokenContract: auction.auctionCurrency, tokenId: 0, amount: auction.amount});

        emit ExchangeExecuted(auction.seller, auction.bidder, userAExchangeDetails, userBExchangeDetails);
        emit AuctionEnded(_tokenContract, _tokenId, auction.bidder, auction.finder, auction);

        delete auctionForNFT[_tokenContract][_tokenId];
    }

    /// @notice Cancels an auction
    /// @param _tokenContract The address of the ERC-721 token
    /// @param _tokenId The ID of the ERC-721 token
    function cancelAuction(address _tokenContract, uint256 _tokenId) external {
        Auction storage auction = auctionForNFT[_tokenContract][_tokenId];

        require(auction.seller != address(0), "cancelAuction auction doesn't exist");
        require(auction.firstBidTime == 0, "cancelAuction auction already started");

        address tokenOwner = IERC721(_tokenContract).ownerOf(_tokenId);
        require(
            msg.sender == tokenOwner || IERC721(_tokenContract).isApprovedForAll(tokenOwner, msg.sender),
            "cancelAuction must be token owner or operator"
        );

        _cancelAuction(_tokenContract, _tokenId);
    }

    /// @dev Deletes canceled and invalid auctions
    /// @param _tokenContract The address of the ERC-721 token
    /// @param _tokenId The ID of the ERC-721 token
    function _cancelAuction(address _tokenContract, uint256 _tokenId) private {
        emit AuctionCanceled(_tokenContract, _tokenId, auctionForNFT[_tokenContract][_tokenId]);

        delete auctionForNFT[_tokenContract][_tokenId];
    }
}
