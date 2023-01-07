// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
// import "hardhat/console.sol";

contract NFTAuction is Context, ERC721Holder, Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    event UpdateTokenList(address newContractAddress, bool enable);
    event DepositNft(
        address indexed contractAddress,
        uint256 indexed tokenId,
        address indexed owner,
        uint256 startTime,
        uint256 endTime,
        uint256 price
    );
    event WithdrawNft(address indexed contractAddress, uint256 indexed tokenId, address indexed owner);

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

    uint256 public constant BID_TIMEOUT = 2 hours;
    uint256 public constant BID_INCREASE_RATE = 3;
    uint256 public constant DENOMINATOR = 100;

    IERC20 auctionToken; // RUCK
    IERC20 paymentToken; // USDC

    uint256 serviceFeeRate;

    mapping(address => bool) public includedTokenList;
    mapping(bytes32 => NftInfo) public listOfNfts;

    modifier onlyIncludedNft(address contractAddress) {
        require(includedTokenList[contractAddress]);
        _;
    }

    modifier onlyNftOwner(address contractAddress, uint256 tokenId) {
        require(_msgSender() == listOfNfts[getNftId(contractAddress, tokenId)].owner);
        _;
    }

    constructor(address usdcAddress) {
        paymentToken = IERC20(usdcAddress);
        serviceFeeRate = 3;
    }

    function updateServiceFeeRate(uint256 newRate) external onlyOwner {
        serviceFeeRate = newRate;
    }

    /// @dev
    function updateTokenList(address newContractAddress, bool isEnabled) external onlyOwner {
        require(newContractAddress != address(0));
        includedTokenList[newContractAddress] = isEnabled;

        emit UpdateTokenList(newContractAddress, isEnabled);
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
            listOfNfts[nftId].currentPrice.mul(BID_INCREASE_RATE).div(DENOMINATOR)
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
        nftInfo.dateOfEnd = listOfNfts[nftId].dateOfEnd.add(BID_TIMEOUT);
        nftInfo.startPrice = listOfNfts[nftId].startPrice;
        nftInfo.currentPrice = nextPrice;
        nftInfo.serviceFeeAmount = listOfNfts[nftId].serviceFeeAmount.add(serviceFee);
        nftInfo.isEnabled = 1;

        listOfNfts[nftId] = nftInfo;
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
        SafeERC20.safeTransfer(paymentToken, address(this), listOfNfts[nftId].currentPrice.sub(serviceFeeRate));

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
