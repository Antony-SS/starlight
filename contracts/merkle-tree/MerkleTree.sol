/**
// SPDX-License-Identifier: CC0-1
A base contract which handles Merkle Tree inserts (and consequent updates to the root and 'frontier' (see below)).
The intention is for other 'derived' contracts to import this contract, and for those derived contracts to manage permissions to actually call the insertLeaf/insertleaves functions of this base contract.

@Author iAmMichaelConnor
*/

pragma solidity ^0.8.0;

import "./MiMC.sol"; // import contract with MiMC function
// import "../access/Ownable.sol";

contract MerkleTree is MiMC {

    /*
    @notice Explanation of the Merkle Tree in this contract:
    This is an append-only merkle tree; populated from left to right.
    We do not store all of the merkle tree's nodes. We only store the right-most 'frontier' of nodes required to calculate the new root when the next new leaf value is added.

                      TREE (not stored)                       FRONTIER (stored)

                                 0                                     ?
                          /             \
                   1                             2                     ?
               /       \                     /       \
           3             4               5               6             ?
         /   \         /   \           /   \           /    \
       7       8      9      10      11      12      13      14        ?
     /  \    /  \   /  \    /  \    /  \    /  \    /  \    /  \
    15  16  17 18  19  20  21  22  23  24  25  26  27  28  29  30      ?

    level  row  width  start#     end#
      4     0   2^0=1   w=0     2^1-1=0
      3     1   2^1=2   w=1     2^2-1=2
      2     2   2^2=4   w=3     2^3-1=6
      1     3   2^3=8   w=7     2^4-1=14
      0     4   2^4=16  w=15    2^5-1=30

    height = 4
    w = width = 2 ** height = 2^4 = 16
    #nodes = (2 ** (height + 1)) - 1 = 2^5-1 = 31

    */

    /**
    These events are what the merkle-tree microservice's filters will listen for.
    */
    event NewLeaf(uint indexed leafIndex, uint indexed leafValue, uint indexed root);
    event NewLeaves(uint indexed minLeafIndex, uint[] leafValues, uint indexed root);

    // event Output(uint[] input, uint[] output, uint prevNodeIndex, uint nodeIndex); // for debugging only

    uint public constant zero = 0;
    uint public constant treeHeight = 32;
    uint public constant treeWidth = uint64(2 ** treeHeight);
    uint public leafCount; // the number of leaves currently in the tree

    /**
    @dev
    Whilst ordinarily, we'd work solely with bytes32, we need to truncate nodeValues up the tree. Therefore, we need to declare certain variables with lower byte-lengths:
    LEAF_HASHLENGTH = 32 bytes;
    NODE_HASHLENGTH = 27 bytes;
    5 byte difference * 8 bits per byte = 40 bit shift to truncate hashlengths.
    27 bytes * 2 inputs to sha() = 54 byte input to sha(). 54 = 0x36.
    If in future you want to change the truncation values, search for '27', '40' and '0x36'.
    */

    uint[33] public frontier; //  = new uint[](treeHeight + 1); // the right-most 'frontier' of nodes required to calculate the new root when the next new leaf value is added.

    /**
    @notice Get the index of the frontier (or 'storage slot') into which we will next store a nodeValue (based on the leafIndex currently being inserted). See the top-level README for a detailed explanation.
    @param leafIndex - the index of the leaf being added
    @return slot - the index of the frontier (or 'storage slot') into which we will next store a nodeValue
    */
    function getFrontierSlot(uint leafIndex) public pure returns (uint slot) {
        slot = 0;
        if ( leafIndex % 2 == 1 ) {
            uint exp1 = 1;
            uint pow1 = 2;
            uint pow2 = pow1 << 1;
            while (slot == 0) {
                if ( (leafIndex + 1 - pow1) % pow2 == 0 ) {
                    slot = exp1;
                } else {
                    pow1 = pow2;
                    pow2 = pow2 << 1;
                    ++exp1;
                }
            }
        }
    }

    /**
    @notice Insert a leaf into the Merkle Tree, update the root, and update any values in the (persistently stored) frontier.
    @param leafValue - the value of the leaf being inserted.
    @return root - the root of the merkle tree, after the insert.
    */
    function insertLeaf(uint leafValue) public returns (uint root) {
        // Cache variables so they aren't continually read from storage
        (uint treeHeight_, uint treeWidth_, uint leafCount_) = (treeHeight, treeWidth, leafCount);
        // check that space exists in the tree:
        require(treeWidth_ > leafCount_, "There is no space left in the tree.");

        uint slot = getFrontierSlot(leafCount_);
        uint nodeIndex = leafCount_ + treeWidth_ - 1;
        uint prevNodeIndex;
        uint nodeValue = leafValue; // nodeValue is the hash, which iteratively gets overridden to the top of the tree until it becomes the root.

        uint[] memory input = new uint[](2); //input of the hash fuction
        uint[] memory output = new uint[](1); // output of the hash function

        for (uint level = 0; level < treeHeight_;) {

            if (level == slot) frontier[slot] = nodeValue;

            if (nodeIndex % 2 == 0) {
                // even nodeIndex
                input[0] = frontier[level];
                input[1] = nodeValue;

                output[0] = mimcHash(input); // mimc hash of concatenation of each node
                nodeValue = output[0]; // the parentValue, but will become the nodeValue of the next level
                prevNodeIndex = nodeIndex;
                nodeIndex = (nodeIndex - 1) / 2; // move one row up the tree
                // emit Output(input, output, prevNodeIndex, nodeIndex); // for debugging only
            } else {
                // odd nodeIndex
                input[0] = nodeValue;
                input[1] = zero;

                output[0] = mimcHash(input); // mimc hash of concatenation of each node
                nodeValue = output[0]; // the parentValue, but will become the nodeValue of the next level
                prevNodeIndex = nodeIndex;
                nodeIndex = nodeIndex / 2; // move one row up the tree
                // emit Output(input, output, prevNodeIndex, nodeIndex); // for debugging only
            }
            unchecked {
                ++level; // GAS OPT: we know this won't overflow
            }
        }

        root = nodeValue;
        root = uint(bytes32(root));

        emit NewLeaf(leafCount_, leafValue, root); // this event is what the merkle-tree microservice's filter will listen for.

        ++leafCount; // the incrememnting of leafCount costs us 20k for the first leaf, and 5k thereafter

        return root; //the root of the tree
    }

    /**
    @notice Insert multiple leaves into the Merkle Tree, and then update the root, and update any values in the (persistently stored) frontier.
    @param leafValues - the values of the leaves being inserted.
    @return root - the root of the merkle tree, after all the inserts.
    */
    function insertLeaves(uint[] memory leafValues) public returns (uint root) {
        // read pertinent vars into memory from storage in one operation
        (uint treeHeight_, uint treeWidth_, uint leafCount_) = (treeHeight, treeWidth, leafCount);

        uint numberOfLeaves = leafValues.length;

        // check that space exists in the tree:
        require(treeWidth_ > leafCount_, "There is no space left in the tree.");
        if (numberOfLeaves > treeWidth_ - leafCount_) {
            uint numberOfExcessLeaves = numberOfLeaves - (treeWidth_ - leafCount_);
            // remove the excess leaves, because we only want to emit those we've added as an event:
            for (uint xs = 0; xs < numberOfExcessLeaves; ++xs) {
                /*
                  CAUTION!!! This attempts to succinctly achieve leafValues.pop() on a **memory** dynamic array. Not thoroughly tested!
                  Credit: https://ethereum.stackexchange.com/a/51897/45916
                */

                assembly {
                  mstore(leafValues, sub(mload(leafValues), 1))
                }
            }
            numberOfLeaves = treeWidth_ - leafCount_;
        }

        uint slot;
        uint nodeIndex;
        uint prevNodeIndex;
        uint nodeValue;

        uint[] memory input = new uint[](2);
        uint[] memory output = new uint[](1); // the output of the hash

        // consider each new leaf in turn, from left to right:
        for (uint leafIndex = leafCount_; leafIndex < leafCount_ + numberOfLeaves; ++leafIndex) {
            nodeValue = leafValues[leafIndex - leafCount_];
            nodeIndex = leafIndex + treeWidth_ - 1; // convert the leafIndex to a nodeIndex

            slot = getFrontierSlot(leafIndex); // determine at which level we will next need to store a nodeValue

            if (slot == 0) {
                frontier[slot] = nodeValue; // store in frontier
                continue;
            }

            // hash up to the level whose nodeValue we'll store in the frontier slot:
            for (uint level = 1; level <= slot; ++level) {
                if (nodeIndex % 2 == 0) {
                    // even nodeIndex
                    input[0] = frontier[level - 1]; //replace with push?
                    input[1] = nodeValue;
                    output[0] = mimcHash(input); // mimc hash of concatenation of each node

                    nodeValue = output[0]; // the parentValue, but will become the nodeValue of the next level
                    prevNodeIndex = nodeIndex;
                    nodeIndex = (nodeIndex - 1) / 2; // move one row up the tree
                    // emit Output(input, output, prevNodeIndex, nodeIndex); // for debugging only
                } else {
                    // odd nodeIndex
                    input[0] = nodeValue;
                    input[1] = zero;
                    output[0] = mimcHash(input); // mimc hash of concatenation of each node

                    nodeValue = output[0]; // the parentValue, but will become the nodeValue of the next level
                    prevNodeIndex = nodeIndex;
                    nodeIndex = nodeIndex / 2; // the parentIndex, but will become the nodeIndex of the next level
                    // emit Output(input, output, prevNodeIndex, nodeIndex); // for debugging only
                }
            }
            frontier[slot] = nodeValue; // store in frontier
        }

        // So far we've added all leaves, and hashed up to a particular level of the tree. We now need to continue hashing from that level until the root:
        for (uint level = slot + 1; level <= treeHeight_;) {

            if (nodeIndex % 2 == 0) {
                // even nodeIndex
                input[0] = frontier[level - 1];
                input[1] = nodeValue;
                output[0] = mimcHash(input); // mimc hash of concatenation of each node

                nodeValue = output[0]; // the parentValue, but will become the nodeValue of the next level
                prevNodeIndex = nodeIndex;
                nodeIndex = (nodeIndex - 1) / 2;  // the parentIndex, but will become the nodeIndex of the next level
                // emit Output(input, output, prevNodeIndex, nodeIndex); // for debugging only
            } else {
                // odd nodeIndex
                input[0] = nodeValue;
                input[1] = zero;
                output[0] = mimcHash(input); // mimc hash of concatenation of each node

                nodeValue = output[0]; // the parentValue, but will become the nodeValue of the next level
                prevNodeIndex = nodeIndex;
                nodeIndex = nodeIndex / 2;  // the parentIndex, but will become the nodeIndex of the next level
                // emit Output(input, output, prevNodeIndex, nodeIndex); // for debugging only
            }
            
            unchecked {
                ++level;
            }
        }

        root = nodeValue;
        root = uint(bytes32(root));

        emit NewLeaves(leafCount_, leafValues, root); // this event is what the merkle-tree microservice's filter will listen for.

        leafCount += numberOfLeaves; // the incrementing of leafCount costs us 20k for the first leaf, and 5k thereafter
        return root; //the root of the tree
    }

    // Intial Root for sparse merkle tree
    uint256 public constant Initial_NullifierRoot = 21443572485391568159800782191812935835534334817699172242223315142338162256601;
}
