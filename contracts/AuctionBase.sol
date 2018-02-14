pragma solidity ^0.4.18;

import 'eip820/contracts/EIP820Registry.sol';
import 'eip820/contracts/EIP820Implementer.sol';
import "zeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "zeppelin-solidity/contracts/math/SafeMath.sol";

import "./ERC821.sol";
import "./IAssetHolder.sol";

/// @title AuctionBase
/// @dev Contains models, variables, and internal methods for the auction.
contract AuctionBase is Pausable, IAssetHolder, EIP820Implementer {
  using SafeMath for uint256;

  // Active: Auction is accepting bids and is not cancelled.
  // Cancelled: The seller cancelled the auction.
  // Completed: Winning bid decided, but NFT and bid transfers are yet to happen.
  enum AuctionStatus { Active, Cancelled, Completed }

  struct Auction {
    // static
    address nftAddress; // NFT address
    uint256 tokenId; // ID of the nft
    address seller; // Current owner of NFT
    uint128 bidIncrement; // Minimum bid increment (in Wei)
    uint256 duration; // Block count for when the auction ends
    uint256 startBlock; // Block number when auction started
    uint256 startedAt; // Approximate time for when the auction was started

    // state
    uint256 highestBid; // Current highest bid
    address highestBidder; // Address of current highest bidder
    bool cancelled; // Flag for cancelled auctions
    bool completed;
  }

  // Map from token ID to their corresponding auction ID.
  mapping (address => mapping(uint256 => uint256)) nftToTokenIdToAuctionId;
  mapping (address => uint256) auctionHouseBalances; // Mapping of addresses to funds
  Auction[] public auctions;

  // Cut the auction house takes on each auction, measured in points (1/100 of a percent).
  // Values 0-10,000 map to 0%-100%
  uint256 public auctionHouseCut;

  event AuctionCreated(uint256 id, address nftAddress, uint256 tokenId);
  event AuctionSuccessful(uint256 id, address nftAddress, uint256 tokenId);
  event AuctionCancelled(uint256 id, address nftAddress, uint256 tokenId);
  event BidCreated(uint256 id, address nftAddress, uint256 tokenId, address bidder, uint256 bid);
  event AuctionNFTWithdrawal(uint256 id, address nftAddress, uint256 tokenId, address withdrawer);
  event AuctionFundWithdrawal(uint256 id, address nftAddress, uint256 tokenId, address withdrawer, uint256 amount);

  // External functions

  // Constructor
  function AuctionBase(uint256 _cut) public {
    setInterfaceImplementation('IAssetHolder', this);
    owner = msg.sender;
    require(_cut <= 10000);
    auctionHouseCut = _cut;
  }

  // @dev Retrieve auctions count
  function getAuctionsCount() public view returns (uint256) {
    return auctions.length;
  }

  // @dev Returns auction info for an NFT on auction.
  // @param _auctionId - auction index/ID
  function getAuction(uint256 _auctionId)
    external
    view
    returns
  (
    uint256 id,
    address nftAddress,
    uint256 tokenId,
    address seller,
    uint256 bidIncrement,
    uint256 duration,
    uint256 startedAt,
    uint256 startBlock,
    AuctionStatus status,
    uint256 highestBid,
    address highestBidder
  ) {
    Auction memory _auction = auctions[_auctionId];
    AuctionStatus _status = _getAuctionStatus(_auctionId);
    return (
      _auctionId,
      _auction.nftAddress,
      _auction.tokenId,
      _auction.seller,
      _auction.bidIncrement,
      _auction.duration,
      _auction.startedAt,
      _auction.startBlock,
      _status,
      _auction.highestBid,
      _auction.highestBidder
    );
  }

  // @dev Return balance msg.sender 
  function getBalance()
    external
    view
    returns (uint256 balance)
  {
    return auctionHouseBalances[msg.sender];
  }

  // @dev Creates and begins a new auction.
  // @_duration is in seconds and is converted to block count.
  function createAuction(
    address _nftAddress,
    uint256 _tokenId,
    uint256 _bidIncrement,
    uint256 _duration
  )
    external
    whenNotPaused
  {
    // Get nft
    ERC821 nftContract = ERC821(_nftAddress);

    // Require msg.sender to own nft
    require(nftContract.ownerOf(_tokenId) == msg.sender);

    // Require duration to be at least a minute and calculate block count
    require(_duration >= 60);
    uint256 durationBlockCount = _duration.div(uint256(14));

    // Put nft in escrow
    nftContract.transfer(this, _tokenId);

    Auction memory _auction = Auction({
      nftAddress: _nftAddress,
      tokenId: _tokenId,
      seller: msg.sender,
      bidIncrement: uint128(_bidIncrement),
      duration: durationBlockCount,
      startedAt: now,
      startBlock: block.number,
      highestBid: 0,
      highestBidder: address(0),
      cancelled: false,
      sellerWithdrewFunds: false
    });
    uint256 newAuctionId = auctions.push(_auction) - 1;

    // Add auction index to nftToTokenIdToAuctionId mapping
    nftToTokenIdToAuctionId[_nftAddress][_tokenId] = newAuctionId;

    AuctionCreated(newAuctionId, _nftAddress, _tokenId);
  }

  // @dev Implements a simplified English auction
  // Lets msg.sender bid at least highestBid + bidIncrement
  // TODO: Look into the experience of bidding in an English Auction asyncronously
  function bid(uint256 _auctionId, uint256 _newBid)
    external
    payable
    whenNotPaused
    statusIs(AuctionStatus.Active, _auctionId)
    returns (bool success)
  {
    require(_newBid > 0);
    // Add msg.value to auctionHouseBalances for msg.sender
    auctionHouseBalances[msg.sender] = auctionHouseBalances[msg.sender].add(msg.value);

    // Require balance of msg.sender be greater than _newBid
    require(auctionHouseBalances[msg.sender] >= _newBid);

    Auction storage auction = auctions[_auctionId];
    // Require _newBid be greater than or equal to auction's highestBid + bidIncrement
    require(_newBid >= auction.highestBid + auction.bidIncrement);

    // Update auctionHouseBalances of previous highest bidder
    auctionHouseBalances[auction.highestBidder] = auctionHouseBalances[auction.highestBidder].add(auction.highestBid);

    // Deduct _newbid from msg.sender balance
    auctionHouseBalances[msg.sender] = auctionHouseBalances[msg.sender].sub(_newBid);

    // Update auction highestBid and highestBidder
    auction.highestBid = _newBid;
    auction.highestBidder = msg.sender;

    // Emit BidCreated event
    BidCreated(_auctionId, auction.nftAddress, auction.tokenId, msg.sender, _newBid);
    return true;
  }

  // @dev Allow people to withdraw their balances
  function withdrawBalance() public returns (bool success) {
    uint256 transferAmount = auctionHouseBalances[msg.sender];
    auctionHouseBalances[msg.sender] = 0;
    msg.sender.transfer(transferAmount);
    return true;
  }

  function completeAuction(uint256 _auctionId) public returns (bool success) {
    AuctionStatus _status = _getAuctionStatus(_auctionId);
    Auction storage auction = auctions[_auctionId];

    require(!auction.complete && _status == AuctionStatus.Completed);

    auction.complete = true;

    // Calculate house and seller cut using auction.highestBid;
    uint256 highestBid = auction.highestBid;
    uint256 houseCut = _computeAuctionHouseCut(highestBid);
    uint256 sellerCut = highestBid.sub(houseCut);

    // Add houseCut to auctionHouseBalance
    auctionHouseBalances[owner] = auctionHouseBalances[owner].add(houseCut);

    // Add seller amount to auctionHouseBalance
    auctionHouseBalances[auction.seller] = auctionHouseBalances[auction.seller].add(sellerCut);

    return true;
  }

  function withdrawNFTFromAuction(uint256 _auctionId) external returns (bool success) {
    Auction storage auction = auctions[_auctionId];

    // can only be called by auction.highestBidder
    require(msg.sender == auction.highestBidder)

    AuctionStatus _status = _getAuctionStatus(_auctionId);
    require(_status == AuctionStatus.Completed);

    if (!auction.complete) {
      completeAuction(_auctionId);
    }

    _transfer(auction.nftAddress, auction.seller, auction.tokenId);
    return true;
  }

  function cancelAuction(address _nftAddress, uint256 _tokenId) external {
    uint256 auctionId = nftToTokenIdToAuctionId[_nftAddress][_tokenId];
    _cancelAuction(auctionId);
  }

  function cancelAuction(uint256 _auctionId) external {
    _cancelAuction(_auctionId);
  }

  function canImplementInterfaceForAddress(address addr, bytes32 interfaceHash) view public returns(bool) {
    return true;
  }

  function onAssetReceived(uint256, address, address, bytes, address, bytes) public {
    return /* 📨 */;
  }

  /// @dev Reject all Ether from being sent here
  function() external payable {
    revert();
  }

  // Internal functions

  /// @dev Transfers an NFT owned by this contract to another address.
  /// Returns true if the transfer succeeds.
  /// @param _nft - The address of the NFT.
  /// @param _receiver - Address to transfer NFT to.
  /// @param _tokenId - ID of token to transfer.
  function _transfer(address _nft, address _receiver, uint256 _tokenId) internal {
    ERC821 nftContract = ERC821(_nft);

    // it will throw if transfer fails
    nftContract.transfer(_receiver, _tokenId);
  }

  /// @dev Cancels an auction unconditionally.
  function _cancelAuction(uint256 _auctionId)
    internal
    statusIs(AuctionStatus.Active, _auctionId)
    onlyOwner
  {
    Auction storage auction = auctions[_auctionId];

    // Update the highest bidders balance in auctionHouseBalances
    auctionHouseBalances[auction.highestBidder] = auctionHouseBalances[auction.highestBidder].add(auction.highestBid);

    auction.cancelled = true;
    auction.highestBidder = address(0);

    _removeAuction(auction.nftAddress, auction.tokenId);
    _transfer(auction.nftAddress, auction.seller, auction.tokenId);

    AuctionCancelled(_auctionId, auction.nftAddress, auction.tokenId);
  }

  /// @dev Removes an auction from mapping
  function _removeAuction(address _nft, uint256 _tokenId) internal {
    delete nftToTokenIdToAuctionId[_nft][_tokenId];
  }

  function _getAuctionStatus(uint256 _auctionId)
    internal
    view
    returns (AuctionStatus)
  {
    Auction storage auction = auctions[_auctionId];

    if (auction.cancelled) {
      return AuctionStatus.Cancelled;
    }
    else if (auction.startBlock + auction.duration < block.number) {
      return AuctionStatus.Completed;
    }
    else {
      return AuctionStatus.Active;
    }
  }

  /// @dev Computes auction house's cut of a sale.
  /// @param _price - highestBid for the NFT.
  function _computeAuctionHouseCut(uint256 _price) internal view returns (uint256) {
      return _price.mul(auctionHouseCut).div(10000);
  }

  // Modifiers

  modifier onlySeller(uint256 _auctionId) {
    Auction memory auction = auctions[_auctionId];
    require(msg.sender == auction.seller);
    _;
  }

  modifier statusIs(AuctionStatus expectedStatus, uint256 _auctionId) {
    require(expectedStatus == _getAuctionStatus(_auctionId));
    _;
  }
}
