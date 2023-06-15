// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

contract YieldTokenContract is ERC20, Ownable {
    uint256 public constant BASE_RATE_XSEC = 694444444444445;   // * 60 eth (daily) / 86400 (seconds in a day)
    uint256 public constant MINT_GIFT = 8000 ether;             // 8000 eth gift for registering a token (only for the first time)
    uint256 public constant END = 1998480813;                   //  Apr 30 2033 13:33:33 GMT+0000, farming end time

    mapping(address => uint256) public Rewards;
    mapping(address => uint256) public LastUpdate;
    mapping(uint256 => address) public StakedTokenIds;
    mapping(address => uint16) public StakedTokenCount;
    address public StakeableTokensContract;
    bool StakeableTokensContractIsErc1155;
    address public StakeableTokensCreator;
  
    event TokenStaked(uint256 indexed tokenid, address user);
    event RewardPaid(address indexed user, uint256 reward);

    constructor() ERC20("YieldTokenName", "YieldTokenSymbol") {
        StakeableTokensContract = address(0x ... ); // Nft Collection Contract
        StakeableTokensContractIsErc1155 = true;    // Collection is Erc1155 (or Erc721)
        StakeableTokensCreator = address(0x ...);   // Nft Collection Creator Address (needed only for additional check on Opensea storefront contract)
      }
    
    // extra check needed on Opensea collections
    function isValidStakeableToken(uint256 id) view internal returns(bool) {
        if (StakeableTokensCreator == address(0))
            return true;
		// making sure the ID fits the opensea format:
		// first 20 bytes are the maker address
		// next 7 bytes are the nft ID
		// last 5 bytes the value associated to the ID, here will always be equal to 1
		//if (id >> 96 != 0x000000000000000000000000a2548e7ad6cee01eeb19d49bedb359aea3d8ad1d)
        if (id >> 96 != uint256(uint160(StakeableTokensCreator)))
			return false;
		if (id & 0x000000000000000000000000000000000000000000000000000000ffffffffff != 1)
			return false;
		//uint256 id = (_id & 0x0000000000000000000000000000000000000000ffffffffffffff0000000000) >> 40;
		//if (id > 1005 || id == 262 || id == 197 || id == 75 || id == 34 || id == 18 || id == 0)
		//	return false;
		return true;
	}

    function walletHoldsStakeableToken(uint256 stakeableTokenId, address wallet) view internal returns (bool)
    {
        if (StakeableTokensContractIsErc1155) {
            return IERC1155(StakeableTokensContract).balanceOf(wallet, stakeableTokenId) > 0;
        }
        else {
            return IERC721(StakeableTokensContract).ownerOf(stakeableTokenId) == wallet;
        }
    }

    function stakeTokens(uint16 quantity, uint256[] calldata stakeTokenIds) public {
        require(quantity > 0, "cannot be zero");
        require(msg.sender == tx.origin, "no bots");
        require(quantity == stakeTokenIds.length, "tokens err");
        uint16 prevStaked = StakedTokenCount[msg.sender];
        uint16 addStaked = 0;
        for (uint256 i = 0; i < quantity; ) {
            require(isValidStakeableToken(stakeTokenIds[i]), "not stakable token");
            require(walletHoldsStakeableToken(stakeTokenIds[i], msg.sender), "not owner");
            if (StakedTokenIds[stakeTokenIds[i]] != msg.sender)
            {
                if (StakedTokenIds[stakeTokenIds[i]] != address(0)) {
                    // prev owner here.. 
                    address prevOwner = StakedTokenIds[stakeTokenIds[i]];
                    StakedTokenCount[prevOwner] = StakedTokenCount[prevOwner] - 1;
                    updateReward(StakedTokenIds[stakeTokenIds[i]], msg.sender);
                }
                StakedTokenIds[stakeTokenIds[i]] = msg.sender;
                unchecked {
                    addStaked++;
                }    
                emit TokenStaked(stakeTokenIds[i], msg.sender);            
            }
            unchecked {
                i++;
            }
        }
        if (addStaked > 0)
        {            
            updateRewardOnStaked( msg.sender, prevStaked, addStaked);
            StakedTokenCount[msg.sender] = prevStaked + addStaked;
        }
    }

    //function mint(address to, uint256 amount) external onlyOwner {
    //    _mint(to, amount);
    //}

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // called when staking new Tokens
    function updateRewardOnStaked(address user, uint16 prevStaked, uint16 amount) internal {
        uint256 time = min(block.timestamp, END);
        uint256 timerUser = LastUpdate[user];
        unchecked {
            if (timerUser > 0) {
                uint256 reward = Rewards[user] + (prevStaked * BASE_RATE_XSEC * (time - timerUser));
                reward = reward + amount * MINT_GIFT;
                Rewards[user] = reward;
            } else {
                Rewards[user] = Rewards[user] + amount * MINT_GIFT;
            }
        }
        LastUpdate[user] = time;
    }

    function updateReward( address from, address to) internal {
        uint256 time = min(block.timestamp, END);
        uint256 timerFrom = LastUpdate[from];
        if (timerFrom > 0 && time > timerFrom)
            Rewards[from] = Rewards[from] + (StakedTokenCount[from] * BASE_RATE_XSEC * (time - timerFrom));
        if (timerFrom != END && time > timerFrom) {
            LastUpdate[from] = time;
        }
        if (to != address(0)) {
            uint256 timerTo = LastUpdate[to];
            if (timerTo > 0 && time > timerTo)
                Rewards[to] = Rewards[to] + (StakedTokenCount[to] * BASE_RATE_XSEC * (time - timerTo));
            if (timerTo != END && time > timerTo) {
                LastUpdate[to] = time;
            }
        }
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == from);
        _burn(from, amount);
    }

    // withdraw (mint) computed Rewards to the wallet
    function getReward(address to) internal {
        uint256 reward = Rewards[to];
        if (reward > 0) {
            Rewards[to] = 0;
            _mint(to, reward);
            emit RewardPaid(to, reward);
        }
    }

    // check actual Total Claimable balance for the wallet
    function getTotalClaimable(address user) external view returns (uint256) {
        uint256 time = min(block.timestamp, END);
        uint256 pending = 0;
        if (LastUpdate[user] > 0 && time > LastUpdate[user]) {
            pending = (StakedTokenCount[user] * BASE_RATE_XSEC * (time - LastUpdate[user]));
        }
        return Rewards[user] + pending;
    }    

    // update and withdraw (mint) rewards to the wallet
    function withdrawMeowTokenReward() external  {
        updateReward(msg.sender,address(0));
        getReward(msg.sender);
    }    

}
