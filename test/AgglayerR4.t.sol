// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

// PoC audit ronde 4 — AggLayer (agglayer-contracts @ 110bda5a, HEAD tidak bergerak)
// Permukaan BARU yang belum diuji r1-r3:
//  R4-1 Emergency-state transitions end-to-end (real manager + real bridge + real GER):
//       apa yang diblokir saat emergency, apakah verify tetap jalan, dan
//       gate 1 minggu pasca-deaktivasi untuk sequenceForceBatches.
//  R4-2 Jalur permissionless activateEmergencyState setelah 1 minggu tanpa agregasi.
//  R4-3 sequenceBatches dengan maxSequenceTimestamp = 0 (tidak ada lower bound).
//  R4-4 forceBatch dengan transactions kosong.
//  R4-5 PolygonDataCommittee.setupCommittee(required=0) -> verifyMessage lolos
//       dengan pesan kosong.

import "forge-std/Test.sol";
import {AgglayerBridge} from "../src/AgglayerBridge.sol";
import {AgglayerGER} from "../src/AgglayerGER.sol";
import {AgglayerManager} from "../src/AgglayerManager.sol";
import {AgglayerGateway} from "../src/AgglayerGateway.sol";
import {PolygonZkEVMEtrog} from "../src/consensus/zkEVM/PolygonZkEVMEtrog.sol";
import {PolygonRollupBaseEtrog} from "../src/lib/PolygonRollupBaseEtrog.sol";
import {PolygonDataCommittee} from "../src/consensus/validium/PolygonDataCommittee.sol";
import {IAgglayerBridge} from "../src/interfaces/IAgglayerBridge.sol";
import {IPolygonZkEVMBridge} from "../src/interfaces/IPolygonZkEVMBridge.sol";
import {IAgglayerGER} from "../src/interfaces/IAgglayerGER.sol";
import {IBaseLegacyAgglayerGER} from "../src/interfaces/IBaseLegacyAgglayerGER.sol";
import {IAgglayerManager} from "../src/interfaces/IAgglayerManager.sol";
import {IAgglayerGateway} from "../src/interfaces/IAgglayerGateway.sol";
import {IPolygonRollupBase} from "../src/interfaces/IPolygonRollupBase.sol";
import {IVerifierRollup} from "../src/interfaces/IVerifierRollup.sol";
import {IEmergencyManager} from "../src/interfaces/IEmergencyManager.sol";
import {AgglayerManagerNotUpgraded} from "../src/newDeployments/AgglayerManagerNotUpgraded.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts5/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts5/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable4/token/ERC20/IERC20Upgradeable.sol";
import {MockPOL, MockSP1Verifier} from "./AgglayerR2.t.sol";
import {MockSTVerifierTrue, MockGERFull} from "./AgglayerR3.t.sol";

contract AgglayerR4Test is Test {
    MockPOL public pol;
    MockGERFull public mockGer;
    AgglayerBridge public bridgeL1;
    AgglayerGER public gerL1;
    AgglayerGateway public gateway;
    AgglayerManagerNotUpgraded public manager;
    PolygonDataCommittee public committee;

    address public attacker = address(0xA77A);
    bytes32 public constant GENESIS = bytes32(uint256(0x1234ABCD));
    bytes32 public constant L1_INFO_ROOT = bytes32(uint256(0x1234));

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.deal(address(this), 100 ether);

        pol = new MockPOL();
        pol.mint(address(this), 10_000 ether);
        mockGer = new MockGERFull();

        // Gateway (unused beyond manager ctor, left uninitialized)
        AgglayerGateway gwImpl = new AgglayerGateway();
        gateway = AgglayerGateway(
            address(new ERC1967Proxy(address(gwImpl), ""))
        );

        // Bridge impl + proxy (initialized later, once manager proxy exists)
        AgglayerBridge bridgeImpl = new AgglayerBridge();
        bridgeL1 = AgglayerBridge(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(bridgeImpl),
                        address(this),
                        ""
                    )
                )
            )
        );

        // Real manager (GER dep = mock, like r3)
        AgglayerManagerNotUpgraded mgrImpl = new AgglayerManagerNotUpgraded(
            IAgglayerGER(address(mockGer)),
            IERC20Upgradeable(address(pol)),
            IPolygonZkEVMBridge(address(bridgeL1)),
            IAgglayerGateway(address(gateway))
        );
        manager = AgglayerManagerNotUpgraded(
            address(new ERC1967Proxy(address(mgrImpl), ""))
        );
        // trustedAggregator=this, admin=this, timelock=this, emergencyCouncil=this
        manager.initialize(address(this), address(this), address(this), address(this));
        manager.setBatchFee(1 gwei);

        // Real GER (ctor: manager proxy, bridge proxy)
        AgglayerGER gerImpl = new AgglayerGER(
            address(manager),
            address(bridgeL1)
        );
        gerL1 = AgglayerGER(address(new ERC1967Proxy(address(gerImpl), "")));
        gerL1.initialize();

        // Bridge initialized with the REAL manager + REAL GER
        bridgeL1.initialize(
            0,
            address(0),
            0,
            IBaseLegacyAgglayerGER(address(gerL1)),
            address(manager),
            ""
        );

        PolygonDataCommittee committeeImpl = new PolygonDataCommittee();
        committee = PolygonDataCommittee(
            address(new ERC1967Proxy(address(committeeImpl), ""))
        );
        committee.initialize();
    }

    function _etrogImpl() internal returns (address) {
        PolygonZkEVMEtrog impl = new PolygonZkEVMEtrog(
            IAgglayerGER(address(mockGer)),
            IERC20Upgradeable(address(pol)),
            IAgglayerBridge(address(bridgeL1)),
            AgglayerManager(address(manager))
        );
        return address(impl);
    }

    function _attachST(uint64 chainID) internal returns (uint32 rollupID, address rollupProxy) {
        manager.addNewRollupType(
            _etrogImpl(),
            address(new MockSTVerifierTrue()),
            9,
            IAgglayerManager.VerifierType.StateTransition,
            GENESIS,
            "r4-test-type",
            bytes32(0)
        );
        uint32 typeID = manager.rollupTypeCount();
        manager.attachAggchainToAL(
            typeID,
            chainID,
            abi.encode(
                address(this), // admin
                address(this), // sequencer = test contract
                address(0), // gas token
                "https://seq.example",
                "testnet"
            )
        );
        rollupID = manager.rollupCount();
        rollupProxy = manager.rollupIDToRollupData(rollupID).rollupContract;
        pol.approve(rollupProxy, type(uint256).max);
    }

    function _sequenceOneBatch(
        address rollupProxy,
        bytes memory txs,
        uint64 maxSeqTs,
        address l2Coinbase
    ) internal returns (uint64 newLastBatch) {
        PolygonRollupBaseEtrog rollup = PolygonRollupBaseEtrog(rollupProxy);
        bytes32 prevAcc = rollup.lastAccInputHash();
        bytes32 expected = keccak256(
            abi.encodePacked(
                prevAcc,
                keccak256(txs),
                L1_INFO_ROOT,
                maxSeqTs,
                l2Coinbase,
                bytes32(0)
            )
        );
        PolygonRollupBaseEtrog.BatchData[] memory batches = new PolygonRollupBaseEtrog.BatchData[](1);
        batches[0] = PolygonRollupBaseEtrog.BatchData({
            transactions: txs,
            forcedGlobalExitRoot: bytes32(0),
            forcedTimestamp: 0,
            forcedBlockHashL1: bytes32(0)
        });
        rollup.sequenceBatches(batches, 0, maxSeqTs, expected, l2Coinbase);
        return manager.rollupIDToRollupData(1).lastBatchSequenced;
    }

    // External wrapper so vm.expectRevert can target the sequenceBatches call
    // (expectRevert does not apply through internal helper frames).
    function _sequenceOneBatchExternal(
        address rollupProxy,
        bytes memory txs,
        uint64 maxSeqTs,
        address l2Coinbase
    ) external {
        PolygonRollupBaseEtrog rollup = PolygonRollupBaseEtrog(rollupProxy);
        bytes32 prevAcc = rollup.lastAccInputHash();
        bytes32 expected = keccak256(
            abi.encodePacked(
                prevAcc,
                keccak256(txs),
                L1_INFO_ROOT,
                maxSeqTs,
                l2Coinbase,
                bytes32(0)
            )
        );
        PolygonRollupBaseEtrog.BatchData[] memory batches = new PolygonRollupBaseEtrog.BatchData[](1);
        batches[0] = PolygonRollupBaseEtrog.BatchData({
            transactions: txs,
            forcedGlobalExitRoot: bytes32(0),
            forcedTimestamp: 0,
            forcedBlockHashL1: bytes32(0)
        });
        rollup.sequenceBatches(batches, 0, maxSeqTs, expected, l2Coinbase);
    }

    function _verifyBatch(uint32 rollupID, uint64 finalBatch) internal {
        bytes32[24] memory proof;
        manager.verifyBatchesTrustedAggregator(
            rollupID,
            0,
            finalBatch - 1,
            finalBatch,
            bytes32(uint256(0xBEEF)),
            bytes32(uint256(0xCAFE)),
            address(this),
            proof
        );
    }

    // ============ R4-1: emergency transitions end-to-end ==================
    function test_R4_EmergencyBlocksBridgeSequenceForceBatch_ButNotVerify() public {
        (uint32 rollupID, address rollupProxy) = _attachST(1000);
        // Genesis batch is #1; sequence batch #2 as control (works pre-emergency).
        uint64 lastBatch = _sequenceOneBatch(rollupProxy, hex"112233", uint64(block.timestamp), address(0xC01B));
        assertEq(lastBatch, 2, "batch 2 sequenced pre-emergency");
        // One aggregation so lastAggregationTimestamp != 0.
        _verifyBatch(rollupID, 1);
        assertGt(manager.lastAggregationTimestamp(), 0, "aggregation timestamp set");

        // Force a batch now (needed later for the post-deactivation gate check).
        uint64 forceTs = uint64(vm.getBlockTimestamp()); // via_ir CSE quirk: never read TIMESTAMP opcode across a warp
        bytes32 forceBh = blockhash(block.number - 1);
        PolygonRollupBaseEtrog(rollupProxy).forceBatch(hex"deadbeef", manager.getForcedBatchFee());
        assertEq(PolygonRollupBaseEtrog(rollupProxy).lastForceBatch(), 1, "forced batch recorded");

        // Activate emergency (council = this).
        manager.activateEmergencyState();
        assertTrue(manager.isEmergencyState(), "manager emergency on");
        assertTrue(bridgeL1.isEmergencyState(), "bridge emergency on");

        // bridgeAsset blocked.
        vm.expectRevert(IEmergencyManager.OnlyNotEmergencyState.selector);
        bridgeL1.bridgeAsset{value: 1 wei}(1, address(0xB0B), 1 wei, address(0), false, "");

        // claimAsset blocked (modifier runs before proof verification).
        bytes32[32] memory emptyProof;
        vm.expectRevert(IEmergencyManager.OnlyNotEmergencyState.selector);
        bridgeL1.claimAsset(
            emptyProof, emptyProof, 0, bytes32(0), bytes32(0),
            0, address(0), 0, address(this), 0, ""
        );

        // sequenceBatches blocked (manager.onSequenceBatches has ifNotEmergencyState).
        vm.expectRevert(IEmergencyManager.OnlyNotEmergencyState.selector);
        this._sequenceOneBatchExternal(rollupProxy, hex"4455", uint64(block.timestamp), address(0xC01B));

        // forceBatch blocked (evaluate fee BEFORE expectRevert: the arg
        // call itself would otherwise consume the expectation).
        uint256 forcedFee = manager.getForcedBatchFee();
        vm.expectRevert(abi.encodeWithSignature("ForceBatchesNotAllowedOnEmergencyState()"));
        PolygonRollupBaseEtrog(rollupProxy).forceBatch(hex"99", forcedFee);

        // BUT verifyBatchesTrustedAggregator still works during emergency
        // (no emergency modifier) — the exit/consolidation path stays open.
        _verifyBatch(rollupID, 2);
        assertEq(manager.rollupIDToRollupData(rollupID).lastVerifiedBatch, 2, "batch 2 verified DURING emergency");

        // Deactivate (STOP_EMERGENCY_ROLE = admin = this).
        manager.deactivateEmergencyState();
        assertFalse(manager.isEmergencyState(), "manager emergency off");
        assertFalse(bridgeL1.isEmergencyState(), "bridge emergency off");

        // Bridge works again.
        bridgeL1.bridgeAsset{value: 1 wei}(1, address(0xB0B), 1 wei, address(0), false, "");

        // sequenceForceBatches is STILL blocked for 1 week after deactivation.
        PolygonRollupBaseEtrog.BatchData[] memory fb = new PolygonRollupBaseEtrog.BatchData[](1);
        fb[0] = PolygonRollupBaseEtrog.BatchData({
            transactions: hex"deadbeef",
            forcedGlobalExitRoot: bytes32(0),
            forcedTimestamp: forceTs,
            forcedBlockHashL1: forceBh
        });
        vm.expectRevert(abi.encodeWithSignature("HaltTimeoutNotExpiredAfterEmergencyState()"));
        PolygonRollupBaseEtrog(rollupProxy).sequenceForceBatches(fb);

        // After 8 days the gate opens and the forced batch sequences.
        vm.warp(block.timestamp + 8 days);
        PolygonRollupBaseEtrog(rollupProxy).sequenceForceBatches(fb);
        assertEq(PolygonRollupBaseEtrog(rollupProxy).lastForceBatchSequenced(), 1, "forced batch sequenced after 8d");
    }

    // ============ R4-2: permissionless activation after 1w silence =======
    function test_R4_PermissionlessActivationAfterOneWeekSilence() public {
        // Fresh manager: lastAggregationTimestamp == 0 -> permissionless
        // activation reverts (the zero-check is part of the gate).
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("HaltTimeoutNotExpired()"));
        manager.activateEmergencyState();

        (uint32 rollupID, ) = _attachST(1001);
        _verifyBatch(rollupID, 1);
        uint64 aggTs = manager.lastAggregationTimestamp();

        // 1 day of silence: still gated.
        vm.warp(aggTs + 1 days);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("HaltTimeoutNotExpired()"));
        manager.activateEmergencyState();

        // 8 days of silence: anyone can halt the whole manager+bridge.
        vm.warp(aggTs + 8 days);
        vm.prank(attacker);
        manager.activateEmergencyState();
        assertTrue(manager.isEmergencyState(), "permissionless halt succeeded after 8d silence");
        assertTrue(bridgeL1.isEmergencyState(), "bridge halted too");
    }

    // ============ R4-3: maxSequenceTimestamp has no lower bound ==========
    function test_R4_SequenceBatches_PastMaxTimestampAccepted() public {
        (, address rollupProxy) = _attachST(1002);
        // maxSequenceTimestamp = 0 (far in the past): accepted, no lower check.
        uint64 lastBatch = _sequenceOneBatch(rollupProxy, hex"aabbcc", 0, address(0xC01B));
        assertEq(lastBatch, 2, "batch sequenced with maxSequenceTimestamp=0");
    }

    // ============ R4-4: forceBatch with empty transactions ===============
    function test_R4_ForceBatchEmptyTransactions() public {
        (, address rollupProxy) = _attachST(1003);
        PolygonRollupBaseEtrog rollup = PolygonRollupBaseEtrog(rollupProxy);
        uint64 forceTs = uint64(vm.getBlockTimestamp()); // via_ir CSE quirk: never read TIMESTAMP opcode across a warp
        bytes32 forceBh = blockhash(block.number - 1);
        rollup.forceBatch("", manager.getForcedBatchFee());
        assertEq(rollup.lastForceBatch(), 1, "empty force batch recorded");

        vm.warp(block.timestamp + 6 days); // forceBatchTimeout = 5 days
        PolygonRollupBaseEtrog.BatchData[] memory fb = new PolygonRollupBaseEtrog.BatchData[](1);
        fb[0] = PolygonRollupBaseEtrog.BatchData({
            transactions: "",
            forcedGlobalExitRoot: bytes32(0),
            forcedTimestamp: forceTs,
            forcedBlockHashL1: forceBh
        });
        rollup.sequenceForceBatches(fb);
        assertEq(rollup.lastForceBatchSequenced(), 1, "empty forced batch sequenced");
    }

    // ============ R4-5: DataCommittee with requiredAmountOfSignatures=0 ===
    function test_R4_DataCommitteeZeroRequiredSignaturesPassesEmptyProof() public {
        // Zero members, zero required: verifyMessage accepts an empty message.
        committee.setupCommittee(0, new string[](0), "");
        assertEq(committee.requiredAmountOfSignatures(), 0, "required=0 accepted");
        assertEq(committee.getAmountOfMembers(), 0, "0 members accepted");
        committee.verifyMessage(keccak256("anything"), "");
        // Non-zero members, still required=0: zero signatures pass, but the
        // message must still carry the full committee address list
        // (splitByte = 65*0 = 0, so the whole message IS the address list).
        string[] memory urls = new string[](1);
        urls[0] = "http://member.example";
        address member = address(0x1234);
        committee.setupCommittee(0, urls, abi.encodePacked(member));
        committee.verifyMessage(keccak256("anything"), abi.encodePacked(member));

        // Control: required=1 rejects the empty message.
        committee.setupCommittee(1, urls, abi.encodePacked(member));
        vm.expectRevert();
        committee.verifyMessage(keccak256("anything"), "");
    }
}
