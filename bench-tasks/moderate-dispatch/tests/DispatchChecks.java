package bench;

import com.fasterxml.jackson.databind.JsonNode;
import edu.practice.dispatch.controller.DispatchController;
import edu.practice.dispatch.dto.DispatchPlan;
import edu.practice.dispatch.dto.NewAirMission;
import edu.practice.dispatch.error.ApiExceptionHandler;
import edu.practice.dispatch.error.MissionNotFoundException;
import edu.practice.dispatch.model.*;
import edu.practice.dispatch.repo.MissionRepository;
import edu.practice.dispatch.service.DispatchService;

import java.util.List;

import static bench.Check.*;

/**
 * MODERATE — Emergency Dispatch Energy Planner API.
 * Expected values come from MODERATE_Practice_Paper.docx (formulas, the worked plan example
 * and the six functional checks). Where the paper is ambiguous the test does not assert it
 * (listed under "ambiguities" in task.json).
 */
public class DispatchChecks {
    static final String AIR = "edu.practice.dispatch.model.AirMission";
    static MissionRepository repo; static DispatchService svc; static MiniMvc mvc; static int base;

    /** Fresh state; missions are saved explicitly so tests do not depend on the solution's seed. */
    static void fresh(boolean withAir) throws Exception {
        repo = new MissionRepository();
        repo.save(new GroundMission(101, 12, 3, true));
        repo.save(new GroundMission(102, 4, 2, false));
        if (withAir) repo.save((DispatchMission) make(AIR, 103L, 8, 1, 3, true));
        svc = new DispatchService(repo);
        mvc = new MiniMvc(new DispatchController(svc), new ApiExceptionHandler());
        base = repo.all().size();
    }
    static DispatchMission air(long id, int d, int l, int w, boolean c) throws Exception { return (DispatchMission) make(AIR, id, d, l, w, c); }
    static List<Long> ids(DispatchPlan p) { return p.selected().stream().map(x -> x.id()).toList(); }

    public static void main(String[] a) {
        // ---- GroundMission (Task 1) ----
        test("M-GM-01 ground energy = 2*distance + 5*load (paper: 101 -> 39)", () -> {
            eq(39, new GroundMission(101, 12, 3, true).energyUnits(), "mission 101");
            eq(18, new GroundMission(102, 4, 2, false).energyUnits(), "mission 102");
            eq(0, new GroundMission(9, 0, 0, false).energyUnits(), "zero"); });
        test("M-GM-02 ground priority: medical 3, otherwise 1", () -> {
            eq(3, new GroundMission(1, 1, 1, true).priority(), "medical"); eq(1, new GroundMission(2, 1, 1, false).priority(), "routine"); });
        test("M-GM-03 ground energy never silently overflows int", () -> {
            eq(39, new GroundMission(101, 12, 3, true).energyUnits(), "baseline must work first");
            try { int v = new GroundMission(1, Integer.MAX_VALUE, 0, false).energyUnits(); throw new AssertionError("returned " + v + " instead of rejecting"); }
            catch (RuntimeException expected) { } });
        test("M-GM-04 GroundMission keeps inheritance, isMedical() and parent fields", () -> {
            isTrue(DispatchMission.class.isAssignableFrom(GroundMission.class), "extends DispatchMission");
            GroundMission g = new GroundMission(7, 3, 4, true);
            eq(true, g.isMedical(), "isMedical"); eq(7L, g.getId(), "id"); eq(3, g.getDistanceKm(), "distance"); eq(4, g.getLoadKg(), "load"); });
        // ---- AirMission (Task 2) ----
        test("M-AM-01 AirMission exists with getters and extends DispatchMission", () -> {
            Object m = make(AIR, 103L, 8, 1, 3, true);
            isTrue(m instanceof DispatchMission, "extends DispatchMission");
            eq(3, m.getClass().getMethod("getWindPenalty").invoke(m), "getWindPenalty");
            eq(true, m.getClass().getMethod("isCritical").invoke(m), "isCritical");
            eq(8, ((DispatchMission) m).getDistanceKm(), "distance via parent"); });
        test("M-AM-02 air energy = 3*distance + 8*load + 2*wind (paper: 103 -> 38)", () -> {
            eq(38, air(103, 8, 1, 3, true).energyUnits(), "103"); eq(30, air(104, 6, 1, 2, false).energyUnits(), "104"); });
        test("M-AM-03 air priority: critical 5, otherwise 2 (paper: 103 -> 5)", () -> {
            eq(5, air(103, 8, 1, 3, true).priority(), "critical"); eq(2, air(104, 6, 1, 2, false).priority(), "non-critical"); });
        test("M-AM-04 repository seeds AirMission(103,8,1,3,true)", () -> {
            DispatchMission m = new MissionRepository().find(103);
            isTrue(m != null && m.getClass().getSimpleName().equals("AirMission"), "id 103 must be an AirMission");
            eq(38, m.energyUnits(), "energy"); eq(5, m.priority(), "priority"); });
        // ---- plan(): greedy dispatch (Task 2, 8 marks; Section B) ----
        test("M-PL-01 plan(60,false) selects [103,102], skips [101] (paper example)", () -> {
            fresh(true);
            DispatchPlan p = svc.plan(60, false);
            eq(List.of(103L, 102L), ids(p), "selected ids in order"); eq(List.of(101L), p.skipped(), "skipped");
            eq(56, p.energyUsed(), "energyUsed"); eq(4, p.energyRemaining(), "energyRemaining"); eq(60, p.capacity(), "capacity"); });
        test("M-PL-02 selected lines carry priority and energy", () -> {
            fresh(true);
            var first = svc.plan(60, false).selected().get(0);
            eq(103L, first.id(), "id"); eq(5, first.priority(), "priority"); eq(38, first.energyUnits(), "energy"); });
        test("M-PL-03 plan(60,true) excludes the routine mission 102", () -> {
            fresh(true);
            DispatchPlan p = svc.plan(60, true);
            isTrue(!ids(p).contains(102L), "routine mission 102 must not be selected");
            eq(List.of(103L), ids(p), "selected"); isTrue(p.skipped().contains(101L), "101 does not fit and is skipped");
            eq(38, p.energyUsed(), "energyUsed"); });
        test("M-PL-04 ample capacity selects everything in priority order", () -> {
            fresh(true);
            DispatchPlan p = svc.plan(1000, false);
            eq(List.of(103L, 101L, 102L), ids(p), "order priority desc"); eq(List.of(), p.skipped(), "nothing skipped");
            eq(95, p.energyUsed(), "38+39+18"); eq(905, p.energyRemaining(), "remaining"); });
        test("M-PL-05 boundary: capacity exactly equal to the energy needed fits", () -> {
            fresh(true);
            DispatchPlan p = svc.plan(38, false);
            eq(List.of(103L), ids(p), "103 fits exactly"); eq(38, p.energyUsed(), "used"); eq(0, p.energyRemaining(), "remaining");
            eq(List.of(101L, 102L), p.skipped(), "others skipped in processing order"); });
        test("M-PL-06 greedy keeps scanning: a later smaller mission still fits", () -> {
            fresh(true);
            DispatchPlan p = svc.plan(18, false);
            eq(List.of(102L), ids(p), "only 102 fits"); eq(List.of(103L, 101L), p.skipped(), "skipped in skip order"); });
        test("M-PL-07 ties: same priority -> energy ASC; same energy -> id ASC", () -> {
            fresh(false);
            repo.save(new GroundMission(7, 4, 2, false));    // energy 18, priority 1
            repo.save(new GroundMission(5, 4, 2, false));    // energy 18, priority 1
            repo.save(new GroundMission(6, 1, 1, false));    // energy 7,  priority 1
            DispatchPlan p = svc.plan(10000, false);
            eq(List.of(101L, 6L, 5L, 7L, 102L), ids(p).stream().filter(x -> x != 103L).toList(), "101(p3), then p1 by energy asc (6=7) then id asc among energy 18: 5, 7, 102"); });
        test("M-PL-08 plan rejects non-positive capacity", () -> {
            fresh(true);
            throwsA(IllegalArgumentException.class, "0", () -> svc.plan(0, false));
            throwsA(IllegalArgumentException.class, "-10", () -> svc.plan(-10, true)); });
        test("M-PL-09 planning does not branch on concrete mission types (instanceof)", () -> {
            String src = source("edu/practice/dispatch/service/DispatchService.java");
            isTrue(!src.isEmpty(), "DispatchService.java not found"); isTrue(!src.contains("instanceof"), "DispatchService uses instanceof");
            fresh(true); isTrue(svc.plan(60, false).selected().size() == 2, "plan must be implemented"); });
        // ---- energy(id) (Task 3) ----
        test("M-SV-01 energy(id) returns the mission's energy", () -> {
            fresh(true); eq(39, svc.energy(101), "101"); eq(38, svc.energy(103), "103"); });
        test("M-SV-02 energy of an unknown id raises MissionNotFoundException", () -> {
            fresh(true); throwsA(MissionNotFoundException.class, "id 999", () -> svc.energy(999)); });
        // ---- addAir validation (Task 3, 7 marks) ----
        test("M-SV-03 addAir stores a valid mission (paper POST example) and returns it", () -> {
            fresh(true);
            DispatchMission m = svc.addAir(new NewAirMission(104, 6, 1, 2, false));
            eq(104L, m.getId(), "id"); eq(30, m.energyUnits(), "energy"); eq(2, m.priority(), "priority");
            isTrue(repo.find(104) != null, "persisted"); eq(base + 1, repo.all().size(), "count"); });
        test("M-SV-04 addAir rejects non-positive id and persists nothing", () -> {
            fresh(true);
            throwsA(IllegalArgumentException.class, "id 0", () -> svc.addAir(new NewAirMission(0, 6, 1, 2, false)));
            throwsA(IllegalArgumentException.class, "id -1", () -> svc.addAir(new NewAirMission(-1, 6, 1, 2, false)));
            eq(base, repo.all().size(), "nothing added"); });
        test("M-SV-05 addAir rejects duplicate id and keeps the original", () -> {
            fresh(true);
            throwsA(IllegalArgumentException.class, "dup", () -> svc.addAir(new NewAirMission(103, 6, 1, 2, false)));
            eq(38, repo.find(103).energyUnits(), "original unchanged"); });
        test("M-SV-06 addAir distance must be positive", () -> {
            fresh(true);
            throwsA(IllegalArgumentException.class, "0", () -> svc.addAir(new NewAirMission(104, 0, 1, 2, false)));
            throwsA(IllegalArgumentException.class, "-3", () -> svc.addAir(new NewAirMission(104, -3, 1, 2, false)));
            eq(base, repo.all().size(), "nothing added"); });
        test("M-SV-07 addAir load and wind must be non-negative (zero allowed)", () -> {
            fresh(true);
            throwsA(IllegalArgumentException.class, "load -1", () -> svc.addAir(new NewAirMission(104, 5, -1, 2, false)));
            throwsA(IllegalArgumentException.class, "wind -1", () -> svc.addAir(new NewAirMission(104, 5, 1, -1, false)));
            eq(15, svc.addAir(new NewAirMission(105, 5, 0, 0, false)).energyUnits(), "zero load and wind accepted"); });
        test("M-SV-08 addAir values above 10,000 are rejected; 10,000 itself is accepted", () -> {
            fresh(true);
            throwsA(IllegalArgumentException.class, "distance 10001", () -> svc.addAir(new NewAirMission(104, 10001, 1, 1, false)));
            throwsA(IllegalArgumentException.class, "load 10001", () -> svc.addAir(new NewAirMission(105, 5, 10001, 1, false)));
            throwsA(IllegalArgumentException.class, "wind 10001", () -> svc.addAir(new NewAirMission(106, 5, 1, 10001, false)));
            eq(130000, svc.addAir(new NewAirMission(107, 10000, 10000, 10000, true)).energyUnits(), "all at the boundary"); });
        // ---- error mapping (Task 3) ----
        test("M-ER-01 unknown mission -> HTTP 404 ApiError NOT_FOUND", () -> {
            fresh(true);
            var r = mvc.get("/api/missions/999/energy"); eq(404, r.status(), "status");
            eq("NOT_FOUND", mvc.json().readTree(r.body()).path("code").asText(), "code"); });
        test("M-ER-02 invalid capacity -> HTTP 400 ApiError BAD_REQUEST", () -> {
            fresh(true);
            var r = mvc.get("/api/missions/plan?capacity=0&urgentOnly=false"); eq(400, r.status(), "status");
            JsonNode j = mvc.json().readTree(r.body()); eq("BAD_REQUEST", j.path("code").asText(), "code"); isTrue(!j.path("message").asText().isEmpty(), "message"); });
        // ---- REST endpoints (Task 4 + Section B) ----
        test("M-HT-01 GET /api/missions/101/energy -> {energyUnits:39}", () -> {
            fresh(true);
            var r = mvc.get("/api/missions/101/energy"); eq(200, r.status(), "status");
            eq(39, mvc.json().readTree(r.body()).path("energyUnits").asInt(), "energyUnits"); });
        test("M-HT-02 GET /api/missions/103/energy -> 38", () -> {
            fresh(true); eq(38, mvc.json().readTree(mvc.get("/api/missions/103/energy").body()).path("energyUnits").asInt(), "energyUnits"); });
        test("M-HT-03 GET /plan?capacity=60&urgentOnly=false -> paper example body", () -> {
            fresh(true);
            var r = mvc.get("/api/missions/plan?capacity=60&urgentOnly=false"); eq(200, r.status(), "status");
            JsonNode j = mvc.json().readTree(r.body());
            eq(60, j.path("capacity").asInt(), "capacity"); eq(56, j.path("energyUsed").asInt(), "energyUsed"); eq(4, j.path("energyRemaining").asInt(), "energyRemaining");
            eq(2, j.path("selected").size(), "selected size"); eq(103, j.path("selected").get(0).path("id").asInt(), "sel[0]"); eq(102, j.path("selected").get(1).path("id").asInt(), "sel[1]");
            eq(1, j.path("skipped").size(), "skipped size"); eq(101, j.path("skipped").get(0).asInt(), "skipped[0]"); });
        test("M-HT-04 urgentOnly defaults to false when omitted", () -> {
            fresh(true);
            JsonNode j = mvc.json().readTree(mvc.get("/api/missions/plan?capacity=60").body());
            eq(56, j.path("energyUsed").asInt(), "same as urgentOnly=false"); });
        test("M-HT-05 urgentOnly=true over HTTP excludes the routine mission", () -> {
            fresh(true);
            JsonNode j = mvc.json().readTree(mvc.get("/api/missions/plan?capacity=60&urgentOnly=true").body());
            for (JsonNode s : j.path("selected")) isTrue(s.path("id").asInt() != 102, "102 selected under urgentOnly"); });
        test("M-HT-06 POST /api/missions/air -> 201 with the created mission", () -> {
            fresh(true);
            var r = mvc.post("/api/missions/air", "{\"id\":104,\"distanceKm\":6,\"loadKg\":1,\"windPenalty\":2,\"critical\":false}");
            eq(201, r.status(), "status"); JsonNode j = mvc.json().readTree(r.body());
            eq(104, j.path("id").asInt(), "id"); eq(6, j.path("distanceKm").asInt(), "distanceKm"); eq(1, j.path("loadKg").asInt(), "loadKg"); });
        test("M-HT-07 after a POST, planning incorporates the new mission", () -> {
            fresh(true);
            eq(201, mvc.post("/api/missions/air", "{\"id\":104,\"distanceKm\":6,\"loadKg\":1,\"windPenalty\":2,\"critical\":false}").status(), "post");
            JsonNode j = mvc.json().readTree(mvc.get("/api/missions/plan?capacity=60&urgentOnly=false").body());
            eq(103, j.path("selected").get(0).path("id").asInt(), "103 first"); eq(102, j.path("selected").get(1).path("id").asInt(), "102 second");
            eq(2, j.path("skipped").size(), "skipped size"); eq(101, j.path("skipped").get(0).asInt(), "skipped[0]"); eq(104, j.path("skipped").get(1).asInt(), "skipped[1]");
            eq(30, mvc.json().readTree(mvc.get("/api/missions/104/energy").body()).path("energyUnits").asInt(), "new mission energy"); });
        test("M-HT-08 invalid POST payloads -> 400 and nothing persisted", () -> {
            fresh(true);
            eq(400, mvc.post("/api/missions/air", "{\"id\":0,\"distanceKm\":6,\"loadKg\":1,\"windPenalty\":2,\"critical\":false}").status(), "id 0");
            eq(400, mvc.post("/api/missions/air", "{\"id\":105,\"distanceKm\":-1,\"loadKg\":1,\"windPenalty\":2,\"critical\":false}").status(), "negative distance");
            eq(400, mvc.post("/api/missions/air", "{\"id\":103,\"distanceKm\":6,\"loadKg\":1,\"windPenalty\":2,\"critical\":false}").status(), "duplicate id");
            eq(base, repo.all().size(), "nothing persisted"); });
        test("M-HT-09 GET /api/missions lists the missions", () -> {
            fresh(true); eq(3, mvc.json().readTree(mvc.get("/api/missions").body()).size(), "size"); });
    }
}
