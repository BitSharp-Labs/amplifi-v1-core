// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721, IERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {IBookkeeper} from "amplifi-v1-common/interfaces/IBookkeeper.sol";
import {IRegistrar} from "amplifi-v1-common/interfaces/IRegistrar.sol";
import {IWithdrawFungibleTokenCallback} from "amplifi-v1-common/interfaces/callbacks/IWithdrawFungibleTokenCallback.sol";
import {IWithdrawFungibleTokensCallback} from
    "amplifi-v1-common/interfaces/callbacks/IWithdrawFungibleTokensCallback.sol";
import {IWithdrawNonFungibleTokenCallback} from
    "amplifi-v1-common/interfaces/callbacks/IWithdrawNonFungibleTokenCallback.sol";
import {TokenInfo, TokenType, TokenSubtype} from "amplifi-v1-common/models/TokenInfo.sol";
import {Addressable} from "amplifi-v1-common/utils/Addressable.sol";
import {PositionHelper, Position} from "../utils/PositionHelper.sol";

contract Bookkeeper is IBookkeeper, Addressable, ERC721 {
    using PositionHelper for Position;
    using SafeERC20 for IERC20;

    IRegistrar private immutable s_REGISTRAR;
    address private s_pud;
    address private s_treasurer;

    mapping(uint256 => Position) private s_positions;
    mapping(address => uint256) private s_totalFungibleTokenBalances;
    mapping(address => mapping(uint256 => uint256)) private s_nonFungibleTokenPositions;

    modifier ensurePosition(uint256 positionId) {
        //TODO:
        _;
    }

    modifier requireOwnerOrOperator(address owner) {
        require(_msgSender() == owner || isApprovedForAll(owner, _msgSender()), "Bookkeeper: require owner or operator");
        _;
    }

    modifier validatePosition(uint256 positionId) {
        require(_exists(positionId), "Bookkeeper: position does not exist");
        _;
    }

    modifier validateToken(address token, TokenType type_) {
        TokenInfo memory tokenInfo = s_REGISTRAR.getTokenInfoOf(token);
        require(tokenInfo.enabled, "Bookkeeper: token is not enabled");
        require(tokenInfo.type_ == type_, "Bookkeeper: token is wrong type");
        _;
    }

    modifier validateTokens(address[] calldata tokens, TokenType type_) {
        for (uint256 i = 0; i < tokens.length; i++) {
            TokenInfo memory tokenInfo = s_REGISTRAR.getTokenInfoOf(tokens[i]);
            require(tokenInfo.enabled, "Bookkeeper: token is not enabled");
            require(tokenInfo.type_ == type_, "Bookkeeper: token is wrong type");
        }
        _;
    }

    constructor(string memory name, string memory symbol, address registrar) ERC721(name, symbol) {
        s_REGISTRAR = IRegistrar(registrar);
        s_REGISTRAR.setBookkeeper(address(this));
    }

    function initialize() external {
        require(s_pud == address(0) && s_treasurer == address(0), "Bookkeeper: already initialized");

        s_pud = s_REGISTRAR.getPUD();
        s_treasurer = s_REGISTRAR.getTreasurer();
    }

    function depositFungibleToken(uint256 positionId, address token)
        external
        validatePosition(positionId)
        validateToken(token, TokenType.Fungible)
        returns (uint256 amount)
    {
        amount = _debitFungibleToken(s_positions[positionId], token);

        emit DepositFungibleToken(_msgSender(), positionId, token, amount);
    }

    function depositNonFungibleToken(uint256 positionId, address token, uint256 tokenId)
        external
        validatePosition(positionId)
        validateToken(token, TokenType.NonFungible)
    {
        require(IERC721(token).ownerOf(tokenId) == address(this), "Bookkeeper: non-fungible token deposit not received");
        require(s_nonFungibleTokenPositions[token][tokenId] == 0, "Bookkeeper: non-fungible token already deposited");

        s_positions[positionId].addNonFungibleToken(token, tokenId);
        s_nonFungibleTokenPositions[token][tokenId] = positionId;

        emit DepositNonFungibleToken(_msgSender(), positionId, token, tokenId);
    }

    function withdrawFungibleToken(
        uint256 positionId,
        address token,
        uint256 amount,
        address recipient,
        bytes calldata data
    )
        external
        ensurePosition(positionId)
        validatePosition(positionId)
        validateToken(token, TokenType.Fungible)
        requireOwnerOrOperator(ownerOf(positionId))
        requireNonZeroAddress(recipient)
        returns (bytes memory callbackResult)
    {
        _creditFungibleToken(s_positions[positionId], token, amount);
        IERC20(token).safeTransfer(recipient, amount);
        if (Address.isContract(_msgSender())) {
            callbackResult = IWithdrawFungibleTokenCallback(_msgSender()).withdrawFungibleTokenCallback(
                positionId, token, amount, recipient, data
            );
        }

        emit WithdrawFungibleToken(_msgSender(), positionId, token, amount, recipient);
    }

    function withdrawFungibleTokens(
        uint256 positionId,
        address[] calldata tokens,
        uint256[] calldata amounts,
        address recipient,
        bytes calldata data
    )
        external
        ensurePosition(positionId)
        validatePosition(positionId)
        validateTokens(tokens, TokenType.Fungible)
        requireOwnerOrOperator(ownerOf(positionId))
        requireNonZeroAddress(recipient)
        returns (bytes memory callbackResult)
    {
        Position storage s_position = s_positions[positionId];
        require(tokens.length == amounts.length, "Bookkeeper: tokens and amounts are different in length");

        for (uint256 i = 0; i < tokens.length; i++) {
            _creditFungibleToken(s_position, tokens[i], amounts[i]);
            IERC20(tokens[i]).safeTransfer(recipient, amounts[i]);
        }
        if (Address.isContract(_msgSender())) {
            callbackResult = IWithdrawFungibleTokensCallback(_msgSender()).withdrawFungibleTokensCallback(
                positionId, tokens, amounts, recipient, data
            );
        }

        emit WithdrawFungibleTokens(_msgSender(), positionId, tokens, amounts, recipient);
    }

    function withdrawNonFungibleToken(
        uint256 positionId,
        address token,
        uint256 tokenId,
        address recipient,
        bytes calldata data
    )
        external
        ensurePosition(positionId)
        validatePosition(positionId)
        validateToken(token, TokenType.NonFungible)
        requireOwnerOrOperator(ownerOf(positionId))
        requireNonZeroAddress(recipient)
        returns (bytes memory callbackResult)
    {
        require(IERC721(token).ownerOf(tokenId) == address(this), "Bookkeeper: token not present");
        require(s_nonFungibleTokenPositions[token][tokenId] == positionId, "Bookkeeper: token not in the position");

        s_positions[positionId].removeNonFungibleToken(token, tokenId);
        delete s_nonFungibleTokenPositions[token][tokenId];
        IERC721(token).safeTransferFrom(address(this), recipient, tokenId);
        if (Address.isContract(_msgSender())) {
            callbackResult = IWithdrawNonFungibleTokenCallback(_msgSender()).withdrawNonFungibleTokenCallback(
                positionId, token, tokenId, recipient, data
            );
        }

        emit WithdrawNonFungibleToken(_msgSender(), positionId, token, tokenId, recipient);
    }

    function onERC721Received(
        address, /* operator */
        address, /* from */
        uint256, /* tokenId */
        bytes calldata /* data */
    ) external view validateToken(_msgSender(), TokenType.NonFungible) returns (bytes4 identifier) {
        identifier = this.onERC721Received.selector;
    }

    function _debitFungibleToken(Position storage s_position, address token) private returns (uint256 amount) {
        uint256 totalBalance = s_totalFungibleTokenBalances[token];
        amount = IERC20(token).balanceOf(address(this)) - totalBalance;
        require(amount > 0, "Bookkeeper: fungible token deposit not received");

        s_position.addFungibleToken(token, amount);
        s_totalFungibleTokenBalances[token] = totalBalance + amount;
    }

    function _creditFungibleToken(Position storage s_position, address token, uint256 amount) private {
        require(s_position.fungibleBalances[token] >= amount, "Bookkeeper: insufficient token balance");

        s_position.removeFungibleToken(token, amount);
        s_totalFungibleTokenBalances[token] -= amount;
    }
}