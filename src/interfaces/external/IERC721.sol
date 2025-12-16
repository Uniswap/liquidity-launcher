// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IERC721
/// @notice Minimal interface for an ERC721 token
interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
}
