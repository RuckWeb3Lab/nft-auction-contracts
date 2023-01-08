// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
// import "hardhat/console.sol";

contract NFTAuction is Context, TimelockController, Ownable2Step, ReentrancyGuard {
    using SafeMath for uint256;

    event UpdateAllownedTokenList(address newContractAddress, bool enable);

    event UpdateServiceConfig(
        uint256 newServiceFeeRate,
        uint256 newBidIncreaseRate,
        uint256 newBidTimeout,
        uint256 newBidTimeOutCondition
    );

    event Bid(
        address indexed bidder,
        address indexed contractAddress,
        uint256 tokenId,
        uint256 bidPrice
    );

    struct NftInfo {
        address owner;
        address lastBidder;
        uint256 dateOfListed;
        uint256 dateOfEnd;
        uint256 startPrice;
        uint256 currentPrice;
        uint256 serviceFeeAmount;
        uint8 isEnabled;
    }

    uint256 public constant DENOMINATOR = 100;

    IERC20 auctionToken; // RUCK
    IERC20 paymentToken; // USDC

    uint256 public bidTimeout;
    uint256 public bidTimeOutCondition;
    uint256 public bidIncreaseRate;
    uint256 public serviceFeeRate;
    uint256 private _totalServiceFeeAmount;

    mapping(address => bool) public allowedTokenList;
    mapping(bytes32 => NftInfo) public listOfNfts;

    modifier onlyIncludedNft(address contractAddress) {
        require(allowedTokenList[contractAddress]);
        _;
    }

    modifier onlyNftOwner(address contractAddress, uint256 tokenId) {
        require(_msgSender() == listOfNfts[getNftId(contractAddress, tokenId)].owner);
        _;
    }

    constructor(
        address usdcAddress,
        address[] memory proposers,
        address[] memory executors
    )
        TimelockController(1 days, proposers, executors, _msgSender())
    {
        paymentToken = IERC20(usdcAddress);
        serviceFeeRate = 3;
        bidIncreaseRate = 3;
        bidTimeout = 2 hours;
        bidTimeOutCondition = 1 hours;
    }

    /// @dev
    function updateServiceConfig(
        uint256 newServiceFeeRate,
        uint256 newBidIncreaseRate,
        uint256 newBidTimeout,
        uint256 newBidTimeOutCondition
    )
        external
        onlyOwner
    {
        serviceFeeRate = newServiceFeeRate;
        bidIncreaseRate = newBidIncreaseRate;
        bidTimeout = newBidTimeout;
        bidTimeOutCondition = newBidTimeOutCondition;

        emit UpdateServiceConfig(serviceFeeRate, bidIncreaseRate, bidTimeout, bidTimeOutCondition);
    }

    /// @dev オークションで利用できるNFTの有効区分を更新
    function updateAllowrdTokenList(address newContractAddress, bool isEnabled) external onlyOwner {
        require(newContractAddress != address(0));
        allowedTokenList[newContractAddress] = isEnabled;

        emit UpdateAllownedTokenList(newContractAddress, isEnabled);
    }

    /// @dev
    function isEndedAuction(
        address contractAddress,
        uint256 tokenId
    )
        public
        view
        onlyIncludedNft(contractAddress)
        returns(bool)
    {
        return (block.timestamp >= listOfNfts[getNftId(contractAddress, tokenId)].dateOfEnd);
    }

    /// @dev
    function getNftInfo(
        address contractAddress,
        uint256 tokenId
    )
        external
        view
        onlyIncludedNft(contractAddress)
        returns(NftInfo memory)
    {
        return listOfNfts[getNftId(contractAddress, tokenId)];
    }

    /// @dev 入札
    function bid(
        address contractAddress,
        uint256 tokenId,
        uint256 bidPrice
    )
        external
        nonReentrant
        onlyIncludedNft(contractAddress)
    {
        bytes32 nftId = getNftId(contractAddress, tokenId);
        uint256 nextPrice = listOfNfts[nftId].currentPrice.add(
            listOfNfts[nftId].currentPrice.mul(bidIncreaseRate).div(DENOMINATOR)
        );

        // オークションが終了していないか確認
        require(isEndedAuction(contractAddress, tokenId) == false);
        // 直近の入札者が自分でないか確認
        require(_msgSender() != listOfNfts[nftId].lastBidder);
        // 入札価格が不足していないか確認
        require(bidPrice >= nextPrice);

        // 入札価格をデポジット
        SafeERC20.safeTransfer(paymentToken, address(this), bidPrice);

        // 一つ前の入札者のデポジットを返却
        uint256 serviceFee = listOfNfts[nftId].currentPrice.mul(serviceFeeRate).div(DENOMINATOR);
        SafeERC20.safeTransfer(paymentToken, listOfNfts[nftId].lastBidder, listOfNfts[nftId].currentPrice.sub(serviceFee));

        // 入札情報を更新
        NftInfo memory nftInfo;
        nftInfo.owner = listOfNfts[nftId].owner;
        nftInfo.lastBidder = _msgSender();
        nftInfo.dateOfListed = listOfNfts[nftId].dateOfListed;
        if (block.timestamp > listOfNfts[nftId].dateOfEnd.sub(bidTimeOutCondition)) {
            nftInfo.dateOfEnd = listOfNfts[nftId].dateOfEnd.add(bidTimeout);
        } else {
            nftInfo.dateOfEnd = listOfNfts[nftId].dateOfEnd;
        }
        nftInfo.startPrice = listOfNfts[nftId].startPrice;
        nftInfo.currentPrice = nextPrice;
        nftInfo.serviceFeeAmount = listOfNfts[nftId].serviceFeeAmount.add(serviceFee);
        nftInfo.isEnabled = 1;

        listOfNfts[nftId] = nftInfo;

        emit Bid(_msgSender(), contractAddress, tokenId, bidPrice);
    }

    /// @dev 出品処理
    /// @param contractAddress address
    /// @param tokenId uint256
    /// @param startPrice uint256
    function sell(
        address contractAddress,
        uint256 tokenId,
        uint256 startPrice,
        uint256 dateOfEnd
    )
        external
        nonReentrant
    {
        IERC721(contractAddress).safeTransferFrom(_msgSender(), address(this), tokenId, "");

        NftInfo memory nftInfo;
        nftInfo.owner = _msgSender();
        nftInfo.lastBidder = address(0);
        nftInfo.dateOfListed = block.timestamp;
        nftInfo.dateOfEnd = dateOfEnd;
        nftInfo.startPrice = startPrice;
        nftInfo.currentPrice = startPrice;
        nftInfo.serviceFeeAmount = 0;
        nftInfo.isEnabled = 1;

        listOfNfts[getNftId(contractAddress, tokenId)] = nftInfo;
    }

    /// @dev キャンセル処理
    /// @notice 入札されるとロックされる (キャンセルができなくなる)
    /// @param contractAddress address
    /// @param tokenId uint256
    function cancel(
        address contractAddress,
        uint256 tokenId
    )
        external
        nonReentrant
        onlyNftOwner(contractAddress, tokenId)
    {
        require(listOfNfts[getNftId(contractAddress, tokenId)].lastBidder == address(0));

        IERC721(contractAddress).safeTransferFrom(address(this), _msgSender(), tokenId, "");

        resetNftInfo(getNftId(contractAddress, tokenId));
    }

    /// @dev オークション終了後に実行
    /// @notice 出品者が実行する
    function finalWithdraw(
        address contractAddress,
        uint256 tokenId
    )
        external
        nonReentrant
        onlyNftOwner(contractAddress, tokenId)
    {
        // オークションが終了しているか確認
        require(isEndedAuction(contractAddress, tokenId) == true);

        bytes32 nftId = getNftId(contractAddress, tokenId);

        // The Keyを入札者に送信
        IERC721(contractAddress).safeTransferFrom(address(this), listOfNfts[nftId].lastBidder, tokenId, "");

        // 入札額を出品者に送信
        SafeERC20.safeTransfer(paymentToken, address(this), listOfNfts[nftId].currentPrice);

        // 手数料を加算
        _totalServiceFeeAmount = _totalServiceFeeAmount.add(listOfNfts[nftId].serviceFeeAmount);

        resetNftInfo(nftId);
    }

    /// @dev NFT情報をリセット
    /// @param nftId bytes32
    function resetNftInfo(bytes32 nftId) internal {
        NftInfo memory nftInfo;
        nftInfo.owner = address(0);
        nftInfo.dateOfListed = 0;
        nftInfo.startPrice = 0;
        nftInfo.currentPrice = 0;
        nftInfo.serviceFeeAmount = 0;
        nftInfo.isEnabled = 0;

        listOfNfts[nftId] = nftInfo;
    }

    /// @dev
    function getNftId(address contractAddress, uint256 tokenId) internal pure returns(bytes32) {
        return keccak256(abi.encodePacked(contractAddress, tokenId));
    }
}
