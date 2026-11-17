// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AgglayerBridge} from "../src/AgglayerBridge.sol";
import {AgglayerGER} from "../src/AgglayerGER.sol";
import {AgglayerManager} from "../src/AgglayerManager.sol";
import {AgglayerGateway} from "../src/AgglayerGateway.sol";
import {PolygonZkEVMEtrog} from "../src/consensus/zkEVM/PolygonZkEVMEtrog.sol";
import {AggchainFEP} from "../src/aggchains/AggchainFEP.sol";
import {AggchainBase} from "../src/lib/AggchainBase.sol";
import {IAggchainBase, IAggchainBaseErrors} from "../src/interfaces/IAggchainBase.sol";
import {IAgglayerBridge} from "../src/interfaces/IAgglayerBridge.sol";
import {IPolygonZkEVMBridge} from "../src/interfaces/IPolygonZkEVMBridge.sol";
import {IAgglayerGER} from "../src/interfaces/IAgglayerGER.sol";
import {IBaseLegacyAgglayerGER} from "../src/interfaces/IBaseLegacyAgglayerGER.sol";
import {IAgglayerManager} from "../src/interfaces/IAgglayerManager.sol";
import {IAgglayerGateway} from "../src/interfaces/IAgglayerGateway.sol";
import {IPolygonRollupBase} from "../src/interfaces/IPolygonRollupBase.sol";
import {PolygonConsensusBase} from "../src/lib/PolygonConsensusBase.sol";
import {AgglayerManagerNotUpgraded} from "../src/newDeployments/AgglayerManagerNotUpgraded.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts5/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts5/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts5/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable4/token/ERC20/IERC20Upgradeable.sol";
import {MockPOL, MockSP1Verifier} from "./AgglayerR2.t.sol";
import {MockSTVerifierFalse, MockSTVerifierTrue, MockGERFull, FallbackSucceeds} from "./AgglayerR3.t.sol";

/// @notice Round 8 AggLayer: PolygonRollupManager rollup-type LIFECYCLE
/// (updateRollup, admin handover, obsoleteRollupType, per-type sequence
/// gating, emergency states per rollup, verifier swap after launch).
/// Source at main HEAD 110bda5a (develop cfdca3c2 identical for the manager).
contract AgglayerR8LifecycleTest is Test {
    MockPOL public pol;
    MockGERFull public mockGer;
    AgglayerBridge public bridgeL1;
    AgglayerGateway public gateway;

    address public sequencer = address(0x5EED);
    address public attacker = address(0xA77A); // trusted aggregator in fixtures
    address public newAdmin = address(0xAD11);
    address public aggMgr = address(0xA66);
    address public aggMgr2 = address(0xA67);

    bytes32 public constant GENESIS = bytes32(uint256(0x1234ABCD));

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.deal(address(this), 100 ether);

        pol = new MockPOL();
        mockGer = new MockGERFull();

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
            "r8-test-type",
            bytes32(0)
        );
        typeID = manager2.rollupTypeCount();
    }

    function _addPPType(
        AgglayerManagerNotUpgraded manager2,
        address consensusImpl,
        address verifier,
        bytes32 programVKey
    ) internal returns (uint32 typeID) {
        manager2.addNewRollupType(
            consensusImpl,
            verifier,
            0,
            IAgglayerManager.VerifierType.Pessimistic,
            bytes32(0),
            "r8-test-pp-type",
            programVKey
        );
        typeID = manager2.rollupTypeCount();
    }

    function _addALType(
        AgglayerManagerNotUpgraded manager2,
        address consensusImpl
    ) internal returns (uint32 typeID) {
        manager2.addNewRollupType(
            consensusImpl,
            address(0),
            0,
            IAgglayerManager.VerifierType.ALGateway,
            bytes32(0),
            "r8-test-al-type",
            bytes32(0)
        );
        typeID = manager2.rollupTypeCount();
    }

    function _attachST(
        AgglayerManagerNotUpgraded manager2,
        uint32 typeID,
        uint64 chainID,
        address adminAddr
    ) internal returns (uint32 rollupID, address rollupProxy) {
        manager2.attachAggchainToAL(
            typeID,
            chainID,
            abi.encode(
                adminAddr,
                sequencer,
                address(0),
                "https://seq.example",
                "testnet"
            )
        );
        rollupID = manager2.rollupCount();
        rollupProxy = manager2.rollupIDToRollupData(rollupID).rollupContract;
    }

    function _attachAL(
        AgglayerManagerNotUpgraded manager2,
        uint32 typeID,
        uint64 chainID,
        address aggchainManagerAddr
    ) internal returns (uint32 rollupID, address rollupProxy) {
        manager2.attachAggchainToAL(
            typeID,
            chainID,
            abi.encode(aggchainManagerAddr)
        );
        rollupID = manager2.rollupCount();
        rollupProxy = manager2.rollupIDToRollupData(rollupID).rollupContract;
    }

    function _etrogImpl(
        AgglayerManagerNotUpgraded manager2
    ) internal returns (address) {
        return _etrogImplWith(manager2, bridgeL1);
    }

    function _etrogImplWith(
        AgglayerManagerNotUpgraded manager2,
        AgglayerBridge bridge
    ) internal returns (address) {
        PolygonZkEVMEtrog impl = new PolygonZkEVMEtrog(
            IAgglayerGER(address(mockGer)),
            IERC20Upgradeable(address(pol)),
            IAgglayerBridge(address(bridge)),
            AgglayerManager(address(manager2))
        );
        return address(impl);
    }

    function _fepImpl(
        AgglayerManagerNotUpgraded manager2
    ) internal returns (address) {
        AggchainFEP impl = new AggchainFEP(
            IAgglayerGER(address(mockGer)),
            IERC20Upgradeable(address(pol)),
            IAgglayerBridge(address(bridgeL1)),
            AgglayerManager(address(manager2)),
            IAgglayerGateway(address(gateway))
        );
        return address(impl);
    }

    /// @dev Simulate the sequencer reporting `n` new batches to the manager
    /// (manager only checks rollupAddressToID[msg.sender] != 0).
    function _sequence(
        AgglayerManagerNotUpgraded manager2,
        address rollupProxy,
        uint64 n,
        bytes32 accHash
    ) internal {
        vm.prank(rollupProxy);
        manager2.onSequenceBatches(n, accHash);
    }

    /// @dev Verify ST batches [init, final] with a garbage proof against the
    /// rollup's own verifier (MockSTVerifierTrue accepts, False rejects).
    function _verifyST(
        AgglayerManagerNotUpgraded manager2,
        uint32 rollupID,
        uint64 initNum,
        uint64 finalNum,
        bytes32 newLocalExitRoot
    ) internal {
        bytes32[24] memory garbageProof;
        vm.prank(attacker); // trusted aggregator
        manager2.verifyBatchesTrustedAggregator(
            rollupID,
            0,
            initNum,
            finalNum,
            newLocalExitRoot,
            bytes32(uint256(0xBEEF)),
            attacker,
            garbageProof
        );
    }

    // ============ R8-1: obsoleteRollupType does NOT stop a live rollup =====
    // Doc (AgglayerManager.sol:197): obsolete means "new rollups cannot use
    // this type". Verify/sequence paths never read the obsolete flag.
    function test_R8_ObsoleteType_LiveRollupKeepsSequencingAndVerifying() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();
        address etrog = _etrogImpl(manager2);
        uint32 typeID = _addSTType(manager2, etrog, address(new MockSTVerifierTrue()), 9);
        (uint32 rollupID, address rollupProxy) = _attachST(manager2, typeID, 1001, address(this));

        // Genesis batch 1 sequenced at initialize; verify it, then sequence 2.
        _verifyST(manager2, rollupID, 0, 1, bytes32(uint256(0xFA9E1)));
        assertEq(manager2.getLastVerifiedBatch(rollupID), 1, "batch 1 verified pre-obsolete");
        _sequence(manager2, rollupProxy, 1, bytes32(uint256(0xACC2)));

        // Admin (this) obsoletes the type the live rollup runs on.
        manager2.obsoleteRollupType(typeID);
        (, , , , bool obsolete, , ) = manager2.rollupTypeMap(typeID);
        assertTrue(obsolete, "type flagged obsolete");

        // Live rollup: sequence + verify keep working untouched.
        _sequence(manager2, rollupProxy, 1, bytes32(uint256(0xACC3)));
        assertEq(
            manager2.rollupIDToRollupData(rollupID).lastBatchSequenced,
            3,
            "sequencing continues after obsolete"
        );
        _verifyST(manager2, rollupID, 1, 2, bytes32(uint256(0xFA9E2)));
        assertEq(manager2.getLastVerifiedBatch(rollupID), 2, "verification continues after obsolete");
        assertEq(
            manager2.rollupIDToRollupData(rollupID).lastLocalExitRoot,
            bytes32(uint256(0xFA9E2)),
            "exit root still updates"
        );

        // But the type is dead for NEW uses: attach + update-to-obsolete revert.
        vm.expectRevert(IAgglayerManager.RollupTypeObsolete.selector);
        manager2.attachAggchainToAL(
            typeID,
            1002,
            abi.encode(address(this), sequencer, address(0), "https://seq.example", "testnet")
        );

        uint32 typeOther = _addSTType(manager2, etrog, address(new MockSTVerifierTrue()), 10);
        (uint32 rollupB, address proxyB) = _attachST(manager2, typeOther, 1003, address(this));
        vm.expectRevert(IAgglayerManager.RollupTypeObsolete.selector);
        manager2.updateRollup(ITransparentUpgradeableProxy(payable(proxyB)), typeID, new bytes(0));
        assertEq(manager2.rollupIDToRollupData(rollupB).rollupTypeID, typeOther, "B type unchanged");
    }

    // ============ R8-2: timelock updateRollup ST -> ALGateway strands ======
    // unverified batches. initMigration (the intended path) requires ALL
    // batches verified; plain updateRollup does NOT check that, and after the
    // switch the ST verify/sequence paths revert (OnlyStateTransitionChains).
    function test_R8_UpdateRollup_STtoALGateway_StrandsUnverifiedBatches() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();
        address etrog = _etrogImpl(manager2);
        uint32 typeST = _addSTType(manager2, etrog, address(new MockSTVerifierTrue()), 9);
        (uint32 rollupID, address rollupProxy) = _attachST(manager2, typeST, 1001, address(this));

        // Batch 1 verified, batch 2 sequenced but NOT verified.
        _verifyST(manager2, rollupID, 0, 1, bytes32(uint256(0xFA9E1)));
        _sequence(manager2, rollupProxy, 1, bytes32(uint256(0xACC2)));
        assertEq(manager2.rollupIDToRollupData(rollupID).lastBatchSequenced, 2, "2 sequenced");
        assertEq(manager2.getLastVerifiedBatch(rollupID), 1, "1 verified");

        // Timelock moves the rollup to an ALGateway type (no all-verified check).
        uint32 typeAL = _addALType(manager2, _fepImpl(manager2));
        manager2.updateRollup(ITransparentUpgradeableProxy(payable(rollupProxy)), typeAL, new bytes(0));
        assertEq(
            uint8(manager2.rollupIDToRollupData(rollupID).rollupVerifierType),
            uint8(IAgglayerManager.VerifierType.ALGateway),
            "now ALGateway"
        );
        assertEq(manager2.rollupIDToRollupData(rollupID).verifier, address(0), "verifier zeroed");
        assertFalse(manager2.isRollupMigrating(rollupID), "plain updateRollup sets no migration flag");

        // Batch 2 can never be ST-verified again, and no new batch can sequence.
        bytes32[24] memory garbageProof;
        vm.prank(attacker);
        vm.expectRevert(IAgglayerManager.OnlyStateTransitionChains.selector);
        manager2.verifyBatchesTrustedAggregator(
            rollupID, 0, 1, 2, bytes32(uint256(0xFA9E2)), bytes32(uint256(0xBEEF)), attacker, garbageProof
        );
        vm.prank(rollupProxy);
        vm.expectRevert(IAgglayerManager.OnlyStateTransitionChains.selector);
        manager2.onSequenceBatches(1, bytes32(uint256(0xACC3)));

        assertEq(manager2.rollupIDToRollupData(rollupID).lastBatchSequenced, 2, "batch 2 stuck sequenced");
        assertEq(manager2.getLastVerifiedBatch(rollupID), 1, "batch 2 stuck unverified");

        // Control: initMigration on a fully-verified rollup refuses to leave
        // unverified batches behind (it reverts while any batch is pending).
        uint32 typeST2 = _addSTType(manager2, etrog, address(new MockSTVerifierTrue()), 11);
        (uint32 rollupC, address proxyC) = _attachST(manager2, typeST2, 1002, address(this));
        _sequence(manager2, proxyC, 1, bytes32(uint256(0xACC9)));
        uint32 typePP = _addPPType(manager2, address(new FallbackSucceeds()), address(new MockSP1Verifier()), bytes32(uint256(0x9999)));
        vm.expectRevert(IAgglayerManager.AllSequencedMustBeVerified.selector);
        manager2.initMigration(rollupC, typePP, new bytes(0));
    }

    // ============ R8-3: admin transfer to address(0) is accepted, but =====
    // harmless while the admin is alive (pendingAdmin is overwritable).
    function test_R8_AdminTransfer_ToZeroAddress_RecoverableWhileAdminAlive() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();
        address etrog = _etrogImpl(manager2);
        uint32 typeID = _addSTType(manager2, etrog, address(new MockSTVerifierTrue()), 9);
        (, address rollupProxy) = _attachST(manager2, typeID, 1001, address(this));
        assertEq(IPolygonRollupBase(rollupProxy).admin(), address(this), "admin is test contract");

        // transferAdminRole has NO zero-address check (unlike the aggchain
        // manager transfer): setting pendingAdmin = 0 succeeds.
        PolygonConsensusBase(rollupProxy).transferAdminRole(address(0));
        assertEq(PolygonConsensusBase(rollupProxy).pendingAdmin(), address(0), "pending admin is 0");

        // Nobody can accept a zero pending admin (msg.sender can never be 0).
        vm.prank(attacker);
        vm.expectRevert();
        PolygonConsensusBase(rollupProxy).acceptAdminRole();
        assertEq(IPolygonRollupBase(rollupProxy).admin(), address(this), "admin unchanged");

        // ...but the live admin can simply overwrite pendingAdmin and finish
        // a normal two-step transfer, so no bricking while the admin is alive.
        PolygonConsensusBase(rollupProxy).transferAdminRole(newAdmin);
        vm.prank(newAdmin);
        PolygonConsensusBase(rollupProxy).acceptAdminRole();
        assertEq(IPolygonRollupBase(rollupProxy).admin(), newAdmin, "transfer completed");
        // Note: pendingAdmin is NOT cleared on accept (cosmetic; accept by the
        // current admin is a no-op re-accept).
        assertEq(PolygonConsensusBase(rollupProxy).pendingAdmin(), newAdmin, "pendingAdmin left set");
    }

    // ============ R8-4: admin key lost -> rollup still recoverable ==========
    // via the timelock (updateRollup / rollbackBatches accept _UPDATE_ROLE).
    function test_R8_AdminLost_TimelockCanStillUpdateRollup() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();
        address etrog = _etrogImpl(manager2);
        uint32 typeID = _addSTType(manager2, etrog, address(new MockSTVerifierTrue()), 9);
        address deadAdmin = address(0xDEAD);
        (uint32 rollupID, address rollupProxy) = _attachST(manager2, typeID, 1001, deadAdmin);

        // Admin-only paths are dead for everyone (nobody owns 0xDEAD).
        vm.prank(attacker);
        vm.expectRevert(IAgglayerManager.OnlyRollupAdmin.selector);
        manager2.updateRollupByRollupAdmin(
            ITransparentUpgradeableProxy(payable(rollupProxy)),
            typeID + 1
        );
        vm.prank(attacker);
        vm.expectRevert(IAgglayerManager.NotAllowedAddress.selector);
        manager2.rollbackBatches(IPolygonRollupBase(rollupProxy), 0);

        // Timelock (this) can still upgrade the rollup to a fresh type...
        uint32 typeNew = _addSTType(manager2, etrog, address(new MockSTVerifierTrue()), 10);
        manager2.updateRollup(ITransparentUpgradeableProxy(payable(rollupProxy)), typeNew, new bytes(0));
        assertEq(manager2.rollupIDToRollupData(rollupID).rollupTypeID, typeNew, "timelock upgraded rollup");

        // ...and the rollup keeps sequencing/verifying afterwards.
        _sequence(manager2, rollupProxy, 1, bytes32(uint256(0xACC2)));
        _verifyST(manager2, rollupID, 0, 1, bytes32(uint256(0xFA9E1)));
        assertEq(manager2.getLastVerifiedBatch(rollupID), 1, "still verifiable after timelock rescue");
    }

    // ============ R8-5: aggchainManager handover is a clean two-step =======
    function test_R8_AggchainManagerTransfer_TwoStepWithZeroCheck() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();
        uint32 typeAL = _addALType(manager2, _fepImpl(manager2));
        (uint32 rollupID, address rollupProxy) = _attachAL(manager2, typeAL, 2001, aggMgr);
        assertEq(AggchainBase(rollupProxy).aggchainManager(), aggMgr, "manager set at attach");

        // Zero address is rejected (unlike the ST admin transfer in R8-3).
        vm.prank(aggMgr);
        vm.expectRevert(IAggchainBaseErrors.InvalidZeroAddress.selector);
        AggchainBase(rollupProxy).transferAggchainManagerRole(address(0));

        // Pending manager cannot act before accepting.
        vm.prank(aggMgr);
        AggchainBase(rollupProxy).transferAggchainManagerRole(aggMgr2);
        assertEq(AggchainBase(rollupProxy).pendingAggchainManager(), aggMgr2, "pending set");
        vm.prank(aggMgr2);
        vm.expectRevert(IAggchainBaseErrors.OnlyAggchainManager.selector);
        AggchainBase(rollupProxy).transferAggchainManagerRole(address(0xBEEF));

        // Accept: role moves, pending is CLEARED (unlike the ST admin flow).
        vm.prank(aggMgr2);
        AggchainBase(rollupProxy).acceptAggchainManagerRole();
        assertEq(AggchainBase(rollupProxy).aggchainManager(), aggMgr2, "manager moved");
        assertEq(AggchainBase(rollupProxy).pendingAggchainManager(), address(0), "pending cleared");

        // Old manager can no longer act (e.g. updateRollupByRollupAdmin).
        uint32 typeAL2 = _addALType(manager2, _fepImpl(manager2));
        vm.prank(aggMgr);
        vm.expectRevert(IAggchainBaseErrors.OnlyAggchainManager.selector);
        manager2.updateRollupByRollupAdmin(
            ITransparentUpgradeableProxy(payable(rollupProxy)),
            typeAL2
        );
        rollupID;
    }

    // ============ R8-6: emergency is GLOBAL, verification is NOT gated =====
    function test_R8_EmergencyState_FreezesAllRollupsButNotVerification() public {
        // Dedicated bridge+manager pair wired like production (bridge's
        // polygonRollupManager = the manager itself); the shared setUp bridge
        // points at the test contract instead, so manager-driven emergency
        // activation would revert OnlyRollupManager there.
        AgglayerBridge bridgeImplE = new AgglayerBridge();
        AgglayerBridge bridgeE = AgglayerBridge(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(bridgeImplE),
                        address(this),
                        ""
                    )
                )
            )
        );
        AgglayerManagerNotUpgraded mgrImplE = new AgglayerManagerNotUpgraded(
            IAgglayerGER(address(mockGer)),
            IERC20Upgradeable(address(pol)),
            IPolygonZkEVMBridge(address(bridgeE)),
            IAgglayerGateway(address(gateway))
        );
        AgglayerManagerNotUpgraded manager2 = AgglayerManagerNotUpgraded(
            address(new ERC1967Proxy(address(mgrImplE), ""))
        );
        manager2.initialize(attacker, address(this), address(this), address(this));
        AgglayerGER gerImplE = new AgglayerGER(address(manager2), address(bridgeE));
        AgglayerGER gerE = AgglayerGER(address(new ERC1967Proxy(address(gerImplE), "")));
        gerE.initialize();
        bridgeE.initialize(
            0,
            address(0),
            0,
            IBaseLegacyAgglayerGER(address(gerE)),
            address(manager2),
            ""
        );

        address etrog = _etrogImplWith(manager2, bridgeE);
        uint32 typeID = _addSTType(manager2, etrog, address(new MockSTVerifierTrue()), 9);
        (uint32 rollupA, address proxyA) = _attachST(manager2, typeID, 1001, address(this));
        (uint32 rollupB, address proxyB) = _attachST(manager2, typeID, 1002, address(this));

        // Emergency council (this) activates the global emergency state.
        manager2.activateEmergencyState();
        assertTrue(manager2.isEmergencyState(), "manager emergency on");
        assertTrue(bridgeE.isEmergencyState(), "bridge emergency on too");

        // BOTH rollups are frozen at once: no per-rollup emergency exists,
        // sequencing on either rollup reverts.
        vm.prank(proxyA);
        vm.expectRevert();
        manager2.onSequenceBatches(1, bytes32(uint256(0xACC2)));
        vm.prank(proxyB);
        vm.expectRevert();
        manager2.onSequenceBatches(1, bytes32(uint256(0xACC3)));

        // Verification deliberately CONTINUES during emergency (no modifier on
        // verifyBatchesTrustedAggregator / verifyPessimisticTrustedAggregator),
        // so already-sequenced batches can still finalize.
        _verifyST(manager2, rollupA, 0, 1, bytes32(uint256(0xFA9E1)));
        assertEq(manager2.getLastVerifiedBatch(rollupA), 1, "A verified during emergency");
        _verifyST(manager2, rollupB, 0, 1, bytes32(uint256(0xFA9E2)));
        assertEq(manager2.getLastVerifiedBatch(rollupB), 1, "B verified during emergency");

        // Admin (this, _STOP_EMERGENCY_ROLE) deactivates; sequencing resumes.
        manager2.deactivateEmergencyState();
        assertFalse(manager2.isEmergencyState(), "emergency off");
        _sequence(manager2, proxyA, 1, bytes32(uint256(0xACC4)));
        assertEq(manager2.rollupIDToRollupData(rollupA).lastBatchSequenced, 2, "sequencing resumes");
    }

    // ============ R8-7: verifier swap is atomic; old batches stay ==========
    // provable under the new forkID; pre-upgrade batches cannot re-verify.
    function test_R8_VerifierSwap_AtomicNoStaleWindow() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();
        address etrog = _etrogImpl(manager2);
        address verifierTrue = address(new MockSTVerifierTrue());
        address verifierFalse = address(new MockSTVerifierFalse());
        uint32 typeV1 = _addSTType(manager2, etrog, verifierTrue, 9);
        (uint32 rollupID, address rollupProxy) = _attachST(manager2, typeV1, 1001, address(this));

        _sequence(manager2, rollupProxy, 1, bytes32(uint256(0xACC2)));
        _verifyST(manager2, rollupID, 0, 1, bytes32(uint256(0xFA9E1)));

        // Swap verifier True -> False AND forkID 9 -> 99 in one timelock call.
        uint32 typeV2 = _addSTType(manager2, etrog, verifierFalse, 99);
        manager2.updateRollup(ITransparentUpgradeableProxy(payable(rollupProxy)), typeV2, new bytes(0));
        assertEq(manager2.rollupIDToRollupData(rollupID).verifier, verifierFalse, "verifier swapped");
        assertEq(manager2.rollupIDToRollupData(rollupID).forkID, 99, "forkID swapped");
        assertEq(
            manager2.rollupIDToRollupData(rollupID).lastVerifiedBatchBeforeUpgrade,
            1,
            "LVBBU recorded"
        );

        // The snark input now embeds the NEW forkID (offset 100..108 in the
        // packed encoding: sender 20 + oldRoot 32 + oldAcc 32 + init 8 + chain 8).
        bytes memory snark = manager2.getInputSnarkBytes(
            rollupID, 1, 2, bytes32(uint256(0xFA9E2)), bytes32(uint256(0xBEEF)), bytes32(uint256(0xBEEF))
        );
        uint64 forkInSnark;
        for (uint256 i = 0; i < 8; i++) {
            forkInSnark = (forkInSnark << 8) | uint64(uint8(snark[100 + i]));
        }
        assertEq(forkInSnark, 99, "snark input uses new forkID immediately");

        // No stale-verifier window: the new (rejecting) verifier is enforced
        // at once, garbage proof for batch 2 reverts.
        bytes32[24] memory garbageProof;
        vm.prank(attacker);
        vm.expectRevert(IAgglayerManager.InvalidProof.selector);
        manager2.verifyBatchesTrustedAggregator(
            rollupID, 0, 1, 2, bytes32(uint256(0xFA9E2)), bytes32(uint256(0xBEEF)), attacker, garbageProof
        );

        // Swap back to an accepting verifier (same new forkID 99): the OLD
        // batch 2, sequenced under forkID 9, is still verifiable — the forkID
        // is only a domain separator in the snark input, the prover just
        // regenerates the proof for the new input.
        uint32 typeV3 = _addSTType(manager2, etrog, verifierTrue, 99);
        manager2.updateRollup(ITransparentUpgradeableProxy(payable(rollupProxy)), typeV3, new bytes(0));
        _verifyST(manager2, rollupID, 1, 2, bytes32(uint256(0xFA9E2)));
        assertEq(manager2.getLastVerifiedBatch(rollupID), 2, "old batch verified under new forkID");

        // ...but pre-upgrade batches cannot be re-verified (no double reward).
        vm.prank(attacker);
        vm.expectRevert(IAgglayerManager.InitBatchMustMatchCurrentForkID.selector);
        manager2.verifyBatchesTrustedAggregator(
            rollupID, 0, 0, 1, bytes32(uint256(0xFA9E1)), bytes32(uint256(0xBEEF)), attacker, garbageProof
        );
    }

    // ============ R8-8: updateRollupByRollupAdmin guards ====================
    function test_R8_UpdateRollupByAdmin_GuardsEnforced() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();
        address etrog = _etrogImpl(manager2);
        address verifierTrue = address(new MockSTVerifierTrue());
        uint32 type1 = _addSTType(manager2, etrog, verifierTrue, 9);
        uint32 type2 = _addSTType(manager2, etrog, verifierTrue, 10);
        uint32 type3 = _addSTType(manager2, etrog, verifierTrue, 11);
        uint32 typePP = _addPPType(manager2, address(new FallbackSucceeds()), address(new MockSP1Verifier()), bytes32(uint256(0x9999)));
        (uint32 rollupID, address rollupProxy) = _attachST(manager2, type2, 1001, address(this));

        // Unverified batches block the admin upgrade...
        _sequence(manager2, rollupProxy, 1, bytes32(uint256(0xACC2)));
        vm.expectRevert(IAgglayerManager.AllSequencedMustBeVerified.selector);
        manager2.updateRollupByRollupAdmin(ITransparentUpgradeableProxy(payable(rollupProxy)), type3);

        // ...a non-admin cannot upgrade at all...
        _verifyST(manager2, rollupID, 0, 1, bytes32(uint256(0xFA9E1)));
        _verifyST(manager2, rollupID, 1, 2, bytes32(uint256(0xFA9E2)));
        vm.prank(attacker);
        vm.expectRevert(IAgglayerManager.OnlyRollupAdmin.selector);
        manager2.updateRollupByRollupAdmin(ITransparentUpgradeableProxy(payable(rollupProxy)), type3);

        // ...downgrade to an older type ID is rejected...
        vm.expectRevert(IAgglayerManager.UpdateToOldRollupTypeID.selector);
        manager2.updateRollupByRollupAdmin(ITransparentUpgradeableProxy(payable(rollupProxy)), type1);

        // ...changing verifier type is rejected...
        vm.expectRevert(IAgglayerManager.UpdateNotCompatible.selector);
        manager2.updateRollupByRollupAdmin(ITransparentUpgradeableProxy(payable(rollupProxy)), typePP);

        // ...and a compliant upgrade (higher ID, same type, all verified) works.
        manager2.updateRollupByRollupAdmin(ITransparentUpgradeableProxy(payable(rollupProxy)), type3);
        assertEq(manager2.rollupIDToRollupData(rollupID).rollupTypeID, type3, "admin upgrade ok");
        assertEq(manager2.rollupIDToRollupData(rollupID).forkID, 11, "forkID moved");
    }

    // ============ R8-9: cross-rollup reward dilution ========================
    // calculateRewardPerBatch() = manager POL balance / (totalSequenced -
    // totalVerified) — a GLOBAL denominator. One rollup sequencing junk
    // batches dilutes the per-batch reward of every OTHER rollup.
    function test_R8_RewardDilution_GlobalDenominator() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();
        address etrog = _etrogImpl(manager2);
        address verifierTrue = address(new MockSTVerifierTrue());
        uint32 typeID = _addSTType(manager2, etrog, verifierTrue, 9);
        (uint32 rollupA, address proxyA) = _attachST(manager2, typeID, 1001, address(this));
        (uint32 rollupB, ) = _attachST(manager2, typeID, 1002, address(this));

        // Fund the manager reward pool: 10,000 POL.
        pol.mint(address(manager2), 10_000 ether);

        // 2 genesis batches outstanding -> 5,000 POL per batch.
        uint256 rewardBefore = manager2.calculateRewardPerBatch();
        assertEq(rewardBefore, 5_000 ether, "reward before dilution");

        // Rollup A sequences 8 junk (empty) batches. In production each costs
        // the sequencer getBatchFee() (0.1 POL) + L1 gas, and sequenceBatches
        // is onlyTrustedSequencer — this is the harness shortcut via the
        // manager callback, same accounting effect.
        _sequence(manager2, proxyA, 8, bytes32(uint256(0xACC9)));
        assertEq(manager2.totalSequencedBatches(), 10, "10 sequenced total");

        // Reward per batch collapses 5x for EVERYONE, including rollup B.
        uint256 rewardAfter = manager2.calculateRewardPerBatch();
        assertEq(rewardAfter, 1_000 ether, "reward after dilution");

        // Rollup B's aggregator now collects 1,000 POL instead of 5,000.
        uint256 balBefore = pol.balanceOf(attacker);
        _verifyST(manager2, rollupB, 0, 1, bytes32(uint256(0xFA9EB)));
        assertEq(pol.balanceOf(attacker) - balBefore, 1_000 ether, "B paid diluted reward");
        rollupA;
    }

    // ============ R8-10: isRollupMigrating survives updateRollup ============
    // initMigration sets the flag; _updateRollup never clears it, and the
    // only clearing path is a successful verifyPessimistic (bootstrap cert).
    function test_R8_MigrationFlag_PersistsAcrossUpdateRollup() public {
        AgglayerManagerNotUpgraded manager2 = _deployManager();
        address etrog = _etrogImpl(manager2);
        uint32 typeST = _addSTType(manager2, etrog, address(new MockSTVerifierTrue()), 9);
        (uint32 rollupID, address rollupProxy) = _attachST(manager2, typeST, 1001, address(this));

        _verifyST(manager2, rollupID, 0, 1, bytes32(uint256(0xFA9E1)));

        uint32 typePP = _addPPType(manager2, address(new FallbackSucceeds()), address(new MockSP1Verifier()), bytes32(uint256(0x9999)));
        manager2.initMigration(rollupID, typePP, new bytes(0));
        assertTrue(manager2.isRollupMigrating(rollupID), "migrating after initMigration");
        assertEq(
            uint8(manager2.rollupIDToRollupData(rollupID).rollupVerifierType),
            uint8(IAgglayerManager.VerifierType.Pessimistic),
            "now Pessimistic"
        );

        // Timelock moves the (still migrating) rollup to an ALGateway type.
        uint32 typeAL = _addALType(manager2, _fepImpl(manager2));
        manager2.updateRollup(ITransparentUpgradeableProxy(payable(rollupProxy)), typeAL, new bytes(0));
        assertEq(
            uint8(manager2.rollupIDToRollupData(rollupID).rollupVerifierType),
            uint8(IAgglayerManager.VerifierType.ALGateway),
            "now ALGateway"
        );
        assertTrue(
            manager2.isRollupMigrating(rollupID),
            "migration flag survives updateRollup: no clearing path except a successful verifyPessimistic"
        );
    }
}
