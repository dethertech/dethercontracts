pragma solidity ^0.4.22;

import "zeppelin-solidity/contracts/math/SafeMath.sol";

import "../dth/IDetherToken.sol";

contract Zone {
  using SafeMath for uint;

  // ------------------------------------------------
  // Variables (Getters)
  // ------------------------------------------------

  uint private constant MIN_STAKE = 100 * 1 ether; // DTH, which is also 18 decimals!
  uint private constant BID_PERIOD = 24 * 1 hours;
  uint private constant COOLDOWN_PERIOD = 48 * 1 hours;
  uint private constant ENTRY_FEE_PERCENTAGE = 1;
  address private constant ADDRESS_BURN = 0xffffffffffffffffffffffffffffffffffffffff;


  IDetherToken public dth;

  bytes7 public geohash;

  // add all funds that zone owners can withdraw
  // this can only be an address that became a zoneowner, and at some point
  // in time executed release(), to release ownership of the zone.
  mapping(address => uint) public zoneOwnerWithdraw;

  //
  // zone owner
  //
  struct ZoneOwner {
    address addr;
    uint startTime;
    uint staked;
    uint lastTaxTime;
  }
  ZoneOwner private zoneOwner;

  //
  // auction
  //
  enum AuctionState { Started, Ended }
  struct Auction {
    AuctionState state;
    uint startTime;
    uint endTime;
    address highestBidder;
    uint totalBids;
    uint numBidders;
    mapping (address => uint) bids;
  }
  uint public currentAuctionId;
  mapping(uint => Auction) private auctionIdToAuction;

  //      auctionId address dthInThisAuction
  mapping(uint => mapping(address => uint)) public auctionBids;

  // ------------------------------------------------
  //
  // Events
  //
  // ------------------------------------------------

  event ZoneCreated(address indexed zoneAddress, bytes7 indexed geohash, address indexed zoneOwner, uint dthAmount);

  // ------------------------------------------------
  //
  // Modifiers
  //
  // ------------------------------------------------

  // no modifiers, its confusing

  // ------------------------------------------------
  //
  // Constructor
  //
  // ------------------------------------------------

  // executed by ZoneFactory.sol when this Zone does not yet exist (= not yet deployed)
  constructor(bytes7 _geohash, address _zoneOwner, uint _dthAmount, address _dth)
    public // will be internal and inherited by Zone.sol if this becomes a separate ZoneAuction.sol contract
  {
    require(_geohash != bytes7(0), "geohash cannot be 0x0");
    require(_zoneOwner != address(0), "zoneOwner cannot be 0x0");
    require(_dth != address(0), "dth token cannot be 0x0");
    require(_dthAmount >= MIN_STAKE, "zone dth stake shoulld be at least minimum (100DTH)");

    geohash = _geohash;

    dth = IDetherToken(_dth);

    zoneOwner.addr = _zoneOwner;
    zoneOwner.startTime = now;
    zoneOwner.staked = _dthAmount;
    zoneOwner.lastTaxTime = now;

    // create a Sentinel Auction for the user that first creates this Zone
    Auction memory sentinelAuction = Auction({
      state: AuctionState.Ended,
      startTime: now,
      endTime: now,
      highestBidder: _zoneOwner, // called by zoneFactory.createAndClaim, which passes msg.sender as _zoneOwner
      totalBids: _dthAmount,
      numBidders: 1
    });
    auctionIdToAuction[currentAuctionId] = sentinelAuction;

    auctionBids[currentAuctionId][_zoneOwner] = _dthAmount;

    emit ZoneCreated(address(this), _geohash, _zoneOwner, _dthAmount);
  }

  // ------------------------------------------------
  //
  // Getters
  //
  // ------------------------------------------------

  function getZoneOwner()
    external
    view
    returns (address, uint, uint)
  {
    return (zoneOwner.addr, zoneOwner.startTime, zoneOwner.staked);
  }

  // if we bid 100DTH, how much will that be after the entry fee (1%) has been deducted
  function calcBidMinusEntryFee(uint _bid)
    external
    pure
    returns(uint)
  {
    return _bid.sub(_bid.div(100).mul(ENTRY_FEE_PERCENTAGE));
  }

  function auctionExists(uint _auctionId)
    public
    view
    returns (bool)
  {
    // if aucton does not exist we should get back zero, otherwise this field
    // will contain a block.timestamp, set whe creating an Auction, in constructor() and bid()
    return auctionIdToAuction[_auctionId].startTime > 0;
  }

  function isEmpty()
    public
    view
    returns (bool)
  {
    return zoneOwner.addr == 0;
  }

  // return all fields of a specific auction
  function getAuction(uint _auctionId)
    public
    view
    returns (uint, uint, uint, uint, address, uint, uint)
  {
    // so we get the correct auction.state depending on block.timestamp
    Auction memory auction = auctionIdToAuction[_auctionId];

    return (
      _auctionId,
      uint(auction.state),
      auction.startTime,
      auction.endTime,
      auction.highestBidder,
      auction.totalBids,
      auction.numBidders
    );
  }

  // easy way to get the current(=last) auction
  function getLastAuction()
    external
    view
    returns (uint, uint, uint, uint, address, uint, uint)
  {
    return getAuction(currentAuctionId);
  }

  // ------------------------------------------------
  //
  //
  // Private Functions
  //
  //
  // ------------------------------------------------

  function _calcHarbergerTax(uint startTime, uint endTime, uint dthAmount)
    private
  {
    // TODO: https://programtheblockchain.com/posts/2018/09/19/implementing-harberger-tax-deeds/

    // uint taxAmount = taxTime.mul(2).div(100); // 2%
    // uint bidAmount = _dthAmount.sub(burnAmount); // 98%

    return 0;
  }

  // there really is no other way to keep everything running smoothly
  // we need to run this function at the beginning of every "set" operation
  function _processLiveAuction()
    private
  {
    Auction storage lastAuction = auctionIdToAuction[currentAuctionId];

    // 1. check if the current Auction is still set to Started and endTime has passed
    if (lastAuction.state == AuctionState.Started && now >= lastAuction.endTime) {
      // 1. update current Auction state to Ended
      lastAuction.state = AuctionState.Ended;

      // 2. collect winning bidder address
      address winningBidder = lastAuction.highestBidder;

      // 3. collect winning bid amount
      uint winningAmount = auctionBids[currentAuctionId][winningBidder];

      // 4. reset winning bidders bid from Auction
      auctionBids[currentAuctionId][winningBidder] = 0;

      // 5. check if winning bidder is the same as current zone owner
      if (zoneOwner.addr == winningBidder) {
        // current zone owner always has his stake amount added to all his bids
        // 5.1 calc the new zone stake amount
        // NOTE: we never reach 0 since we take percentage as harberger tax
        uint harbergerTaxToPay = _calcHarbergerTax(zoneOwner.lastTaxTime, now, zoneOwner.staked);

        zoneOwner.staked = zoneOwner.staked.add(winningAmount);

      // 6. winning bidder differs from current zone owner
      } else {
        // 6.1 pay back the staked DTH (minus harberger tax) to the old zone owner
        uint harbergerTaxToPay = _calcHarbergerTax(zoneOwner.lastTaxTime, now, zoneOwner.staked);
        uint amountToPayOut = zoneOwner.staked.sub(harbergerTaxToPay);
        dth.transfer(ADDRESS_BURN, harbergerTaxToPay); // burn tax
        dth.transfer(zoneOwner.addr, amountToPayOut); // return to prev owner

        // 6.2 make the winnig bidder the new zoneOwner
        zoneOwner.addr = winningBidder;
        zoneOwner.staked = winningAmount; // entry fee is already deducted when user calls bid()
        zoneOwer.startTime = lastAuction.endTime;
        zoneOwer.lastTaxTime = now;
      }
    }
  }

  // ------------------------------------------------
  //
  //
  // Public Functions
  //
  //
  // ------------------------------------------------

  // even though we use _processLiveAuction in every "set" function, there still should be a way
  // to manually claim a zone after the auction ended.
  // TODO: there is no claim function, whenever user does something like addTeller
  // and he was the winner of the last (passed) auction, processLiveauction()
  // will update the state to make him owner, after which his addTeller() call will succeed
  //
  // const getLiveZoneOwner = () => {
  //   const zoneOwner = zoneInstance.getZoneOwner()
  //   const lastAuction = zoneInstance.getLastAuction()
  //   const liveZoneOwner =
  //     (lastAuction.endTime > now && zoneOwner.addr !== lastAuction.highestBidder)
  //       ? lastAuction.highestBidde
  //       : zoneOwner.addr
  //   return liveZoneOwner
  // }
  function claim()
    external
  {
    require(now >= auctionIdToAuction[currentAuctionId].endTime, "auction endTime has not yet passed");
    require(auctionIdToAuction[currentAuctionId].state == AuctionState.Started, "auction not in started state");
    require(msg.sender == auctionIdToAuction[currentAuctionId].highestBidder, "can only be called by last auction highest bidder");

    processLiveAuction();
    // nothing
  }

  // user can claim empty zone --> which has no zoneowner AND for which there is no running auction
  function claimEmptyZone(uint _dthAmount)
    external
  {
    processLiveAuction();
    require(isEmpty(), "can only claim a zone which has no owner");
    require(auctionIdToAuction[currentAuctionId].state == AuctionState.Ended, "can not claim while auction is running");
    require(dth.balanceOf(msg.sender) >= _dthAmount, "caller does not have enough dth");
    require(_dthAmount >= MIN_STAKE, "bid needs to be at least minimum zone stake amount (100 DTH)");

    zoneOwner = ZoneOwner({
      addr: msg.sender,
      startTime: now,
      staked: _dthAmount
    });

    dth.transferFrom(msg.sender, address(this), _dthAmount);
  }

  function bid(uint _dthAmount)
    external
  {
    require(dth.allowance(msg.sender, address(this)) >= _dthAmount, "zone does not have high enough dth allowance from sender");
    require(dth.balanceOf(msg.sender) >= _dthAmount, "sender does not have enough dth");

    processLiveAuction();

    // TODO: could also do this before processLiveAuction?!
    // we disallow calling this function when there is currently no zone owner, the user should call claimEmptyZone()
    require(zoneOwner.addr != address(0), "cannot bid on zone without owner, use claim()");

    Auction storage lastAuction = auctionIdToAuction[currentAuctionId];

    uint burnAmount = _dthAmount.div(100).mul(ENTRY_FEE_PERCENTAGE); // 1%
    uint bidAmount = _dthAmount.sub(burnAmount); // 99%

    if (lastAuction.state == AuctionState.Ended) {
      // there has to be a current zone owner
      // let's see if msg.sender can start a new Auction
      require(msg.sender != zoneOwner.addr, "zoneowner cannot start an auction");
      require(bidAmount > zoneOwner.staked, "bid is lower than current zone stake");
      require(now > lastAuction.endTime.add(COOLDOWN_PERIOD), "cooldown period did not end yet");

      // save the new Auction
      uint newAuctionId = ++currentAuctionId;

      auctionIdToAuction[newAuctionId] = Auction({
        state: AuctionState.Started,
        startTime: now,
        endTime: now.add(BID_PERIOD),
        highestBidder: msg.sender, // caller (challenger)
        totalBids: bidAmount, // caller (challenger) dth stake bid
        numBidders: 1
      });

      auctionBids[newAuctionId][msg.sender] = bidAmount;

    } else if (lastAuction.state == AuctionState.Started) {
      // there has to be a current zone owner
      // there is a running auction, lets see if we can join the auction with our bid
      require(msg.sender != lastAuction.highestBidder, "highest bidder cannot bid");

      uint currentUserTotalBid = auctionBids[currentAuctionId][msg.sender];
      uint currentHighestBid = auctionBids[currentAuctionId][lastAuction.highestBidder];

      if (msg.sender == zoneOwner.addr) {
        if (currentUserTotalBid == 0) {
          // zoneowner's first challenge counter-bid
          uint firstCounterBidAmount = zoneOwner.staked.add(bidAmount);
          require(firstCounterBidAmount > currentHighestBid, "bid + already staked is less than current highest");
          auctionBids[currentAuctionId][msg.sender] = firstCounterBidAmount;
        }
      } else {
        // msg.sender is not the current zone owner OR he is the current zone owner but this is not his first counterbid
        uint newUserTotalBid = currentUserTotalBid.add(bidAmount);
        require(newUserTotalBid > currentHighestBid, "bid is less than current highest");
        auctionBids[currentAuctionId][msg.sender] = newUserTotalBid;
      }

      // update the Auction
      lastAuction.highestBidder = msg.sender;
      lastAuction.totalBids = lastAuction.totalBids.add(bidAmount);
    }

    dth.transferFrom(msg.sender, ADDRESS_BURN, burnAmount); // burn
    dth.transferFrom(msg.sender, address(this), bidAmount);
  }

  // user can always try to withdraw from a specific auction
  function withdrawFromAuction(uint _auctionId)
    external
  {
    require(_auctionId <= currentAuctionId, "auctionId does not exist");

    processLiveAuction();

    Auction storage auction = auctionIdToAuction[_auctionId];

    require(auction.state == AuctionState.Ended, "can not withdraw while auction is active");
    require(auction.bids[msg.sender] > 0, "nothing to withdraw");

    uint withdrawAmount = auction.bids[msg.sender];

    auction.bids[msg.sender] = 0;
    auction.totalBids = auction.totalBids.sub(withdrawAmount);

    dth.transfer(msg.sender, withdrawAmount);
  }

  // if this function costs too much gas, the user can still withdraw using the above withdrawFromAuction(auctionId)
  function withdrawFromAllAuctions()
    external
  {
    processLiveAuction();

    uint withdrawAmountTotal = 0;

    for (uint auctionId = 1; auctionId <= currentAuctionId; auctionId++) {
      Auction storage auction = auctionIdToAuction[auctionId];

      uint withdrawAmount = auctionBids[auctionId][msg.sender];
      if (withdrawAmount == 0) continue; // go to next auction

      auctionBids[auctionId][msg.sender] = 0;
      auction.totalBids = auction.totalBids.sub(withdrawAmount);

      withdrawAmountTotal = withdrawAmountTotal.add(withdrawAmount);
    }

    if (withdrawAmountTotal == 0) return;

    dth.transfer(msg.sender, withdrawAmountTotal);
  }

  // zone owner can release his zone ownership
  function release()
    external
  {
    processLiveAuction();

    require(msg.sender == zoneOwner.addr, "can only be called by zoneowner");


    ////////////////////////////////////////////////////////////
    // TODO
    ////////////////////////////////////////////////////////////
  }
}


// problems
// -