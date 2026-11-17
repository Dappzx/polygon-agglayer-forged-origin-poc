// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AgglayerBridge} from "../src/AgglayerBridge.sol";
import {AgglayerGER} from "../src/AgglayerGER.sol";
import {AgglayerManager} from "../src/AgglayerManager.sol";
import {AgglayerGateway} from "../src/AgglayerGateway.sol";
import {PolygonZkEVMEtrog} from "../src/consensus/zkEVM/PolygonZkEVMEtrog.sol";
import {IAgglayerBridge} from "../src/interfaces/IAgglayerBridge.sol";
import {IPolygonZkEVMBridge} from "../src/interfaces/IPolygonZkEVMBridge.sol";
import {IAgglayerGER} from "../src/interfaces/IAgglayerGER.sol";
import {IBaseLegacyAgglayerGER} from "../src/interfaces/IBaseLegacyAgglayerGER.sol";
import {IAgglayerManager} from "../src/interfaces/IAgglayerManager.sol";
import {IAgglayerGateway} from "../src/interfaces/IAgglayerGateway.sol";
import {IPolygonRollupBase} from "../src/interfaces/IPolygonRollupBase.sol";
import {IVerifierRollup} from "../src/interfaces/IVerifierRollup.sol";
import {AgglayerManagerNotUpgraded} from "../src/newDeployments/AgglayerManagerNotUpgraded.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts5/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts5/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts5/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable4/token/ERC20/IERC20Upgradeable.sol";
import {MockPOL, MockSP1Verifier} from "./AgglayerR2.t.sol";

/// @notice ST verifier mock that always rejects the proof.
contract MockSTVerifierFalse is IVerifierRollup {
    function verifyProof(bytes32[24] calldata, uint256[1] calldata) external pure override returns (bool) {
        return false;
    }
}

/// @notice ST verifier mock that always accepts the proof.
contract MockSTVerifierTrue is IVerifierRollup {
    function verifyProof(bytes32[24] calldata, uint256[1] calldata) external pure override returns (bool) {
        return true;
    }
}

/// @notice Fuller GER mock: etrog initialize/sequence paths call
/// getLastGlobalExitRoot(); the manager calls updateExitRoot().
contract MockGERFull {
    mapping(uint32 => bytes32) public l1InfoRootMap;
    constructor() {
        l1InfoRootMap[0] = bytes32(uint256(0x1234));
    }
    function getLastGlobalExitRoot() external pure returns (bytes32) {
        return bytes32(0);
    }
    function getRoot() external pure returns (bytes32) {
        return bytes32(0);
    }
    function updateExitRoot(bytes32) external {}
}

/// @notice A contract with code but no rollup logic: any call succeeds
/// silently via its fallback. Used as a "wrong-code" consensus implementation.
contract FallbackSucceeds {
    fallback() external {}
    receive() external payable {}
}

/// @notice Reads admin() through a HIGH-LEVEL call in its own frame, so a
/// returndata-decode revert is observable via expectRevert (a decode revert
/// happens in the caller's frame, which vm.expectRevert cannot catch when
/// the call is made directly from the test contract).
contract RollupAdminReader {
    function readAdmin(address rollupProxy) external view returns (address) {
        return IPolygonRollupBase(rollupProxy).admin();
    }
}

/// @notice Round 3 AggLayer: defense-in-depth `addNewRollupType` (+ upgrade path
/// and forkID collision). Source at main HEAD 110bda5a (identical to develop
/// for AgglayerManager.sol).
contract AgglayerR3Test is Test {
    MockPOL public pol;
    MockGERFull public mockGer;
    AgglayerBridge public bridgeL1;
    AgglayerGateway public gateway;
    MockSP1Verifier public mockVerifier;

    address public sequencer = address(0x5EED);
    address public attacker = address(0xA77A); // trusted aggregator in fixtures

    bytes32 public constant GENESIS = bytes32(uint256(0x1234ABCD));

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.deal(address(this), 100 ether);

        pol = new MockPOL();
        mockGer = new MockGERFull();
        mockVerifier = new MockSP1Verifier();

        AgglayerBridge bridgeImpl = new AgglayerBridge();
        TransparentUpgradeableProxy bridgeProxy = new TransparentUpgradeableProxy(
            address(bridgeImpl),
            address(this),
            ""
        );
        bridgeL1 = AgglayerBridge(payable(address(bridgeProxy)));
        AgglayerGER gerImpl = new AgglayerGER(address(this), address(bridgeL1));
        ERC1967Proxy gerProxy = new ERC1967Proxy(address(gerImpl), "");
        AgglayerGER gerL1 = AgglayerGER(address(gerProxy));
        bridgeL1.initialize(
            0,
            address(0),
            0,
            IBaseLegacyAgglayerGER(address(gerL1)),
            address(this),
            ""
        );
        gerL1.initialize();

        AgglayerGateway gatewayImpl = new AgglayerGateway();
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), "");
        gateway = AgglayerGateway(address(gatewayProxy));
    }

    function _deployManager() internal returns (AgglayerManagerNotUpgraded manager2) {
        AgglayerManagerNotUpgraded mgrImpl = new AgglayerManagerNotUpgraded(
            IAgglayerGER(address(mockGer)),
            IERC20Upgradeable(address(pol)),
            IPolygonZkEVMBridge(address(bridgeL1)),
            IAgglayerGateway(address(gateway))
        );
        ERC1967Proxy mgrProxy = new ERC1967Proxy(address(mgrImpl), "");
        manager2 = AgglayerManagerNotUpgraded(address(mgrProxy));
        // trustedAggregator=attacker, admin=this, timelock=this, emergencyCouncil=this
        // => _ADD_ROLLUP_TYPE_ROLE + _UPDATE_ROLLUP_ROLE -> timelock (this),
        //    _CREATE_ROLLUP_ROLE -> admin (this).
        manager2.initialize(attacker, address(this), address(this), address(this));
    }

    function _addSTType(
        AgglayerManagerNotUpgraded manager2,
        address consensusImpl,
        address verifier,
        uint64 forkID
    ) internal returns (uint32 typeID) {
        manager2.addNewRollupType(
            consensusImpl,
            verifier,
            forkID,
            IAgglayerManager.VerifierType.StateTransition,
            GENESIS,
            "r3-test-type",
            bytes32(0)
        );
        typeID = manager2.rollupTypeCount();
    }

    function _attachST(
        AgglayerManagerNotUpgraded manager2,
        uint32 typeID,
        uint64 chainID
    ) internal returns (uint32 rollupID, address rollupProxy) {
        manager2.attachAggchainToAL(
            typeID,
            chainID,
            abi.encode(
                address(this), // admin
                sequencer,
                address(0), // gas token
                "https://seq.example",
                "testnet"
            )
        );
        rollupID = manager2.rollupCount();
        rollupProxy = manager2.rollupIDToRollupData(rollupID).rollupContract;
    }

    function _etrogImpl(
        AgglayerManagerNotUpgraded manager2
    ) internal returns (address) {
        PolygonZkEVMEtrog impl = new PolygonZkEVMEtrog(
            IAgglayerGER(address(mockGer)),
            IERC20Upgradeable(address(pol)),
            IAgglayerBridge(address(bridgeL1)),
            AgglayerManager(address(manager2))
        );
        return address(impl);
    }

    function _erc1967Err(address impl) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("ERC1967InvalidImplementation(address)", impl);
    }

    // ============ R3-1: zero-code consensusImplementation is accepted as a TYPE,
    // but attach reverts in the OZ proxy layer (backstop, not a manager check) ====
    function test_R3_ZeroConsensusImpl_TypeAcceptedButAttachReverts() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();

        // addNewRollupType has NO code check on consensusImplementation
        // (only != address(this)) — unlike addExistingRollup, which reverts
        // on rollupAddress.code.length == 0. The type IS created.
        uint32 typeID = _addSTType(manager2, address(0), address(new MockSTVerifierTrue()), 9);
        assertEq(typeID, 1, "type created despite zero implementation");
        (address storedImpl, , , , , , ) = manager2.rollupTypeMap(typeID);
        assertEq(storedImpl, address(0), "stored as 0");

        // attachAggchainToAL deploys PolygonTransparentProxy(0, ...) which
        // reverts in OZ v5 ERC1967Utils._setImplementation:
        // `if (newImplementation.code.length == 0) revert ERC1967InvalidImplementation`.
        // So the zero-code case is backstopped by the proxy library, not by
        // the manager — and the revert consumes nothing.
        vm.expectRevert(_erc1967Err(address(0)));
        manager2.attachAggchainToAL(
            typeID,
            1001,
            abi.encode(address(this), sequencer, address(0), "https://seq.example", "testnet")
        );
        assertEq(manager2.rollupCount(), 0, "no rollup consumed");
        assertEq(manager2.chainIDToRollupID(1001), 0, "chainID not burned");

        // Same for an EOA (no code) implementation.
        uint32 typeEOA = _addSTType(manager2, address(0xE0A), address(new MockSTVerifierTrue()), 9);
        vm.expectRevert(_erc1967Err(address(0xE0A)));
        manager2.attachAggchainToAL(
            typeEOA,
            1002,
            abi.encode(address(this), sequencer, address(0), "https://seq.example", "testnet")
        );
        assertEq(manager2.rollupCount(), 0, "still no rollup");
    }

    // ============ R3-1b: a WRONG-CODE (has code, not a rollup) implementation
    // sails through every check and creates a dead shell rollup ============
    function test_R3_WrongCodeConsensusImpl_AttachCreatesDeadShellRollup() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();

        // Any address WITH code passes the OZ check. A contract whose fallback
        // just succeeds makes initialize() a silent no-op.
        uint32 typeID = _addSTType(
            manager2,
            address(new FallbackSucceeds()),
            address(new MockSTVerifierTrue()),
            9
        );
        (uint32 rollupID, address rollupProxy) = _attachST(manager2, typeID, 1001);
        assertEq(rollupID, 1, "rollup id");
        assertTrue(rollupProxy.code.length > 0, "proxy has code");
        assertEq(manager2.chainIDToRollupID(1001), 1, "chainID registered");

        // Dead shell: at the EVM level every call returns success=true with
        // EMPTY returndata (initialize never ran). A Solidity HIGH-LEVEL
        // caller reverts when decoding the empty returndata (bare revert, no
        // reason string) — proven here via a reader contract, since a decode
        // revert happens in the caller's own frame.
        (bool ok, bytes memory ret) = rollupProxy.staticcall(
            abi.encodeWithSignature("admin()")
        );
        assertTrue(ok, "staticcall to shell succeeds (fallback no-op)");
        assertEq(ret.length, 0, "no returndata: initialize never ran");
        RollupAdminReader reader = new RollupAdminReader();
        vm.expectRevert();
        reader.readAdmin(rollupProxy);

        // The chainID is now burned forever: re-attach reverts, and the shell
        // can never be repaired through attach (only updateRollup to a new
        // type could revive it).
        vm.expectRevert(IAgglayerManager.ChainIDAlreadyExist.selector);
        manager2.attachAggchainToAL(
            typeID,
            1001,
            abi.encode(address(this), sequencer, address(0), "https://seq.example", "testnet")
        );
    }

    // ============ R3-2: containment — shell rollup cannot fake ST verification ====
    function test_R3_ShellRollupCannotFakeSTVerification_HonestVerifier() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();
        uint32 typeID = _addSTType(
            manager2,
            address(new FallbackSucceeds()),
            address(new MockSTVerifierFalse()),
            9
        );
        (uint32 rollupID, address rollupProxy) = _attachST(manager2, typeID, 1002);

        // The shell rollup cannot sequence by itself (its code is a no-op
        // fallback), so simulate a sequenced batch: the manager only checks
        // rollupAddressToID[msg.sender] != 0 in onSequenceBatches, and the
        // shell proxy IS registered. This is what _getInputSnarkBytes needs
        // (sequencedBatches[finalNewBatch].accInputHash != 0) before it even
        // reaches the verifier call.
        vm.prank(rollupProxy);
        manager2.onSequenceBatches(1, bytes32(uint256(0xACC)));

        bytes32 rootBefore = manager2.getRollupExitRoot();
        bytes32[24] memory garbageProof;

        // The manager calls IVerifierRollup(rollup.verifier).verifyProof DIRECTLY
        // (high-level call), never through the rollup implementation, so a
        // wrong-code consensusImplementation cannot influence verification.
        // (ST verifier == address(0) is also safe for the same reason: the
        // high-level call reverts on the solc 0.8.28 extcodesize check, as
        // already proven for Pessimistic in r2 V1.)
        vm.prank(attacker);
        vm.expectRevert(IAgglayerManager.InvalidProof.selector);
        manager2.verifyBatchesTrustedAggregator(
            rollupID,
            0, // pendingStateNum
            0, // initNumBatch (batchNumToStateRoot[0] == GENESIS, non-zero)
            1, // finalNewBatch
            bytes32(uint256(0xFA9E1)),
            bytes32(uint256(0xBEEF)),
            attacker,
            garbageProof
        );

        assertEq(manager2.getRollupExitRoot(), rootBefore, "exit root must not move");
        assertEq(
            manager2.rollupIDToRollupData(rollupID).lastLocalExitRoot,
            bytes32(0),
            "lastLocalExitRoot must stay zero"
        );
        assertEq(manager2.getLastVerifiedBatch(rollupID), 0, "nothing verified");
    }

    // ============ R3-3: updateRollup — zero impl reverts (OZ backstop), wrong-code
    // impl succeeds and bricks a live rollup ====
    function test_R3_UpdateRollup_ZeroImplReverts_WrongCodeImplBricks() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();
        address etrog = _etrogImpl(manager2);

        uint32 typeLegit = _addSTType(manager2, etrog, address(new MockSTVerifierFalse()), 9);
        (uint32 rollupID, address rollupProxy) = _attachST(manager2, typeLegit, 1003);

        // Live rollup: initialize ran, admin is set.
        assertEq(IPolygonRollupBase(rollupProxy).admin(), address(this), "live admin");

        // (a) Upgrade to a zero-implementation type: reverts in OZ
        // ERC1967Utils._setImplementation (same backstop as attach).
        uint32 typeZero = _addSTType(manager2, address(0), address(new MockSTVerifierFalse()), 9);
        vm.expectRevert(_erc1967Err(address(0)));
        manager2.updateRollup(
            ITransparentUpgradeableProxy(payable(rollupProxy)),
            typeZero,
            new bytes(0)
        );
        assertEq(IPolygonRollupBase(rollupProxy).admin(), address(this), "still live after failed upgrade");
        assertEq(manager2.rollupIDToRollupData(rollupID).rollupTypeID, 1, "type unchanged");

        // (b) Upgrade to a wrong-code type: upgradeToAndCall with EMPTY data
        // does NOT call the new implementation, so the OZ functionDelegateCall
        // code check is skipped too — the upgrade SUCCEEDS and bricks the rollup.
        uint32 typeShell = _addSTType(
            manager2,
            address(new FallbackSucceeds()),
            address(new MockSTVerifierFalse()),
            9
        );
        manager2.updateRollup(
            ITransparentUpgradeableProxy(payable(rollupProxy)),
            typeShell,
            new bytes(0)
        );

        assertEq(manager2.rollupIDToRollupData(rollupID).rollupTypeID, 3, "type switched");
        (bool ok, bytes memory ret) = rollupProxy.staticcall(
            abi.encodeWithSignature("admin()")
        );
        assertTrue(ok, "staticcall still succeeds post-brick");
        assertEq(ret.length, 0, "rollup dead after upgrade to wrong-code impl");
        RollupAdminReader reader = new RollupAdminReader();
        vm.expectRevert();
        reader.readAdmin(rollupProxy);
    }

    // ============ R3-4: forkID collision across types does not cross-contaminate ====
    function test_R3_ForkIDCollision_DoesNotCrossContaminateVerifiers() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();
        address etrog = _etrogImpl(manager2);

        // Two types, SAME forkID 7, DIFFERENT verifiers.
        uint32 typeFalse = _addSTType(manager2, etrog, address(new MockSTVerifierFalse()), 7);
        uint32 typeTrue = _addSTType(manager2, etrog, address(new MockSTVerifierTrue()), 7);

        (uint32 rollupA, ) = _attachST(manager2, typeFalse, 2001);
        (uint32 rollupB, ) = _attachST(manager2, typeTrue, 2002);

        assertEq(manager2.rollupIDToRollupData(rollupA).forkID, 7, "A forkID");
        assertEq(manager2.rollupIDToRollupData(rollupB).forkID, 7, "B forkID");
        assertTrue(
            manager2.rollupIDToRollupData(rollupA).verifier !=
                manager2.rollupIDToRollupData(rollupB).verifier,
            "verifiers differ"
        );

        bytes32[24] memory garbageProof;
        bytes32 chosenRoot = bytes32(uint256(0xFA9E1));

        // Rollup A (rejecting verifier) refuses the garbage proof even though
        // rollup B shares its forkID.
        vm.prank(attacker);
        vm.expectRevert(IAgglayerManager.InvalidProof.selector);
        manager2.verifyBatchesTrustedAggregator(
            rollupA, 0, 0, 1, chosenRoot, bytes32(uint256(0xBEEF)), attacker, garbageProof
        );

        // Rollup B (accepting verifier) verifies the SAME garbage proof: the
        // forkID is only a per-rollup domain separator in the snark input, not
        // a global key to a verifier.
        vm.prank(attacker);
        manager2.verifyBatchesTrustedAggregator(
            rollupB, 0, 0, 1, chosenRoot, bytes32(uint256(0xBEEF)), attacker, garbageProof
        );

        assertEq(
            manager2.rollupIDToRollupData(rollupB).lastLocalExitRoot,
            chosenRoot,
            "B exit root set by its own verifier"
        );
        assertEq(
            manager2.rollupIDToRollupData(rollupA).lastLocalExitRoot,
            bytes32(0),
            "A exit root untouched"
        );
        assertEq(manager2.getLastVerifiedBatch(rollupA), 0, "A unverified");
        assertEq(manager2.getLastVerifiedBatch(rollupB), 1, "B verified");
    }

    // ============ R3-5: permissionless caller cannot register a rollup type ====
    function test_R3_AddNewRollupType_RevertsForNonTimelock() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();
        address etrog = _etrogImpl(manager2);
        address falseVerifier = address(new MockSTVerifierFalse());

        vm.prank(attacker); // has only TRUSTED_AGGREGATOR_ROLE, not _ADD_ROLLUP_TYPE_ROLE
        vm.expectRevert();
        manager2.addNewRollupType(
            etrog,
            falseVerifier,
            9,
            IAgglayerManager.VerifierType.StateTransition,
            GENESIS,
            "attacker-type",
            bytes32(0)
        );
        assertEq(manager2.rollupTypeCount(), 0, "no type created");
    }
}
