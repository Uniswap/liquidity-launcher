use alloy_primitives::{address, Address, B256, keccak256};
use rand::Rng;

// Equivalent to Solidity abi.encode(address, bytes32)
pub fn abi_encode_sender_and_salt(sender: Address, salt: B256) -> B256 {
    // 32-byte left-padded address + 32-byte salt
    let mut encoded = [0u8; 64];
    encoded[12..32].copy_from_slice(sender.as_slice()); // left-pad address
    encoded[32..].copy_from_slice(salt.as_slice());
    keccak256(encoded)
}

/// Mine a salt that will result in a contract address with the desired hook permissions mask.
pub fn mine_salt(
    strategy_address: Address,
    init_code_hash: B256,
    hook_permissions_mask: Address,
    msg_sender_address: Address,
    token_launcher_address: Address,
) -> B256 {
    let all_hook_mask: Address = address!("0x0000000000000000000000000000000000003fff");
    loop {
        let salt = B256::from_slice(&rand::thread_rng().gen::<[u8; 32]>());

        // Fix this implementation to do proper abi encoding 
        let salt_with_msg_sender = abi_encode_sender_and_salt(msg_sender_address, salt);
        let salt_with_token_launcher = abi_encode_sender_and_salt(token_launcher_address, salt_with_msg_sender);
        let address = strategy_address.create2(salt_with_token_launcher, init_code_hash);
        if hook_permissions_mask == address & all_hook_mask {
            return salt;
        }
    }
}

/// Checks if an address fulfills vanity requirements
pub fn fulfills_vanity(address: Address, prefix: &str, case_sensitive: bool) -> bool {
    if !case_sensitive {
        let address_str = format!("{:x}", address);
        address_str.starts_with(&prefix.to_lowercase())
    } else {
        let address_str = &address.to_checksum(None)[2..];
        address_str.starts_with(prefix)
    }
}