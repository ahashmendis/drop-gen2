package bench;

import com.fasterxml.jackson.databind.JsonNode;
import edu.practice.scheduler.controller.SchedulerController;
import edu.practice.scheduler.dto.*;
import edu.practice.scheduler.error.*;
import edu.practice.scheduler.model.*;
import edu.practice.scheduler.repo.WorkloadRepository;
import edu.practice.scheduler.service.SchedulerService;

import java.lang.reflect.Field;
import java.util.*;
import java.util.stream.Collectors;

import static bench.Check.*;

/**
 * EXTREME — Multi-Resource Workload Scheduling API.
 * Expected plans were derived BY HAND from EXTREME_Practice_Paper.docx (urgency formulas,
 * half-open intervals, CPU+memory on every tick, ranked order). The paper leaves some things
 * open (rejection-reason precedence when several apply, the ordering key of GET /reservations,
 * the JSON shape of /urgency, 200-vs-201 on commit); tests only assert what the paper fixes.
 * Workloads are injected explicitly so tests do not depend on the solution's repository seed.
 */
public class SchedulerChecks {
    static final String DL = "edu.practice.scheduler.model.DeadlineWorkload";
    static WorkloadRepository repo; static SchedulerService svc; static MiniMvc mvc;

    static Workload dl(long id, int cpu, int mem, int dur, int rel, int dead) throws Exception { return (Workload) make(DL, id, cpu, mem, dur, rel, dead); }
    static Workload[] std() throws Exception {
        return new Workload[]{ new BatchWorkload(1, 2, 4000, 3, 0), dl(2, 4, 6000, 2, 0, 4), new BatchWorkload(3, 2, 2000, 2, 1), dl(4, 3, 6000, 3, 1, 6) };
    }
    @SuppressWarnings("unchecked")
    static void fresh(Workload... ws) throws Exception {
        repo = new WorkloadRepository();
        Field f = WorkloadRepository.class.getDeclaredField("map"); f.setAccessible(true);
        Map<Long, Workload> m = (Map<Long, Workload>) f.get(repo); m.clear();
        for (Workload w : ws) m.put(w.getId(), w);
        svc = new SchedulerService(repo);
        mvc = new MiniMvc(new SchedulerController(svc), new ApiExceptionHandler());
    }
    static String sel(SchedulePlan p) { return p.selected().stream().map(r -> r.id() + "[" + r.startTick() + "," + r.endTickExclusive() + ")").collect(Collectors.joining(" ")); }
    static String rej(SchedulePlan p) { return p.rejected().stream().map(r -> r.id() + ":" + r.reason()).collect(Collectors.joining(" ")); }
    static List<Long> rank(int now) { return svc.ranked(now).stream().map(Workload::getId).toList(); }
    static PlanRequest req(int now, int h, int cpu, int mem) { return new PlanRequest(now, h, cpu, mem); }
    static final String PREVIEW = "{\"nowTick\":0,\"horizon\":6,\"cpuCapacity\":6,\"memoryCapacity\":10000}";
    static String commit(String key, int h) { return "{\"runKey\":\"" + key + "\",\"nowTick\":0,\"horizon\":" + h + ",\"cpuCapacity\":6,\"memoryCapacity\":10000}"; }
    static int urgencyValue(JsonNode j) {
        if (j.isNumber()) return j.asInt();
        for (var it = j.fields(); it.hasNext(); ) { var e = it.next(); if (e.getKey().toLowerCase().contains("urgen") && e.getValue().isNumber()) return e.getValue().asInt(); }
        throw new AssertionError("no numeric urgency in " + j);
    }

    public static void main(String[] a) {
        // ---- BatchWorkload (Task 1) ----
        test("E-BW-01 batch urgency = 100 + 2*max(0, now-release)", () -> {
            eq(100, new BatchWorkload(1, 2, 4000, 3, 0).urgencyAt(0), "now=release=0");
            eq(106, new BatchWorkload(1, 2, 4000, 3, 2).urgencyAt(5), "now 5 release 2");
            eq(100, new BatchWorkload(3, 2, 2000, 2, 1).urgencyAt(0), "now before release does not go below 100");
            eq(2000100, new BatchWorkload(1, 1, 1, 1, 0).urgencyAt(1_000_000), "large legal tick"); });
        test("E-BW-02 batch urgency rejects negative nowTick", () -> {
            eq(100, new BatchWorkload(1, 1, 1, 1, 0).urgencyAt(0), "baseline must work first");
            throwsA(IllegalArgumentException.class, "-1", () -> new BatchWorkload(1, 1, 1, 1, 0).urgencyAt(-1)); });
        test("E-BW-03 batch urgency never wraps around on overflow", () -> {
            eq(100, new BatchWorkload(1, 1, 1, 1, 0).urgencyAt(0), "baseline must work first");
            try { int v = new BatchWorkload(1, 1, 1, 1, 0).urgencyAt(Integer.MAX_VALUE); isTrue(v >= 100, "wrapped to " + v); }
            catch (RuntimeException ok) { } });
        test("E-BW-04 batch latestStartTick is Integer.MAX_VALUE, dispatch works via Workload reference", () -> {
            Workload w = new BatchWorkload(1, 2, 4000, 3, 0);
            eq(Integer.MAX_VALUE, w.latestStartTick(), "latestStartTick"); eq(100, w.urgencyAt(0), "urgencyAt via parent type"); });
        test("E-BW-05 BatchWorkload initialises inherited fields via the parent constructor", () -> {
            Workload w = new BatchWorkload(9, 2, 4000, 3, 5);
            eq(9L, w.getId(), "id"); eq(2, w.getCpuCores(), "cpu"); eq(4000, w.getMemoryMb(), "mem"); eq(3, w.getDurationTicks(), "duration"); eq(5, w.getReleaseTick(), "release"); });
        // ---- DeadlineWorkload (Task 2) ----
        test("E-DW-01 DeadlineWorkload exists, extends Workload, exposes deadline getter", () -> {
            Workload w = dl(2, 4, 6000, 2, 0, 4);
            eq(4, w.getClass().getMethod("getDeadlineTick").invoke(w), "getDeadlineTick");
            eq(2L, w.getId(), "id"); eq(4, w.getCpuCores(), "cpu"); eq(6000, w.getMemoryMb(), "mem"); eq(2, w.getDurationTicks(), "duration"); eq(0, w.getReleaseTick(), "release"); });
        test("E-DW-02 deadline urgency = 1000 - 5*max(0, deadline-now-duration)", () -> {
            Workload w = dl(2, 4, 6000, 2, 0, 4);
            eq(990, w.urgencyAt(0), "now 0 (slack 2)"); eq(995, w.urgencyAt(1), "now 1 (slack 1)"); eq(1000, w.urgencyAt(2), "now 2 (slack 0)");
            eq(1000, w.urgencyAt(3), "now 3 (negative slack clamps to 0)"); eq(1000, w.urgencyAt(10), "now 10");
            eq(985, dl(4, 3, 6000, 3, 1, 6).urgencyAt(0), "workload 4"); });
        test("E-DW-03 deadline latestStartTick = deadline - duration", () -> {
            eq(2, dl(2, 4, 6000, 2, 0, 4).latestStartTick(), "workload 2"); eq(3, dl(4, 3, 6000, 3, 1, 6).latestStartTick(), "workload 4"); });
        test("E-DW-04 deadline urgency uses safe arithmetic (no wraparound)", () -> {
            eq(990, dl(2, 4, 6000, 2, 0, 4).urgencyAt(0), "baseline must work first");
            Workload w = dl(5, 1, 1, 2, 0, 858_993_462);   // 5 * 858,993,460 wraps to a small positive int
            try { int v = w.urgencyAt(0); isTrue(v < 0, "wrapped to " + v + "; the true value is hugely negative"); }
            catch (RuntimeException ok) { } });
        // ---- ranking and lookup (Task 2, 8 marks) ----
        test("E-RK-01 ranked(0) = [2,4,1,3] (paper: deadline 2 ahead of batch 1)", () -> { fresh(std()); eq(List.of(2L, 4L, 1L, 3L), rank(0), "order"); });
        test("E-RK-02 ranked(1) = [2,4,1,3]", () -> { fresh(std()); eq(List.of(2L, 4L, 1L, 3L), rank(1), "order"); });
        test("E-RK-03 ranking is dynamic: ranked(500) = [1,3,2,4]", () -> { fresh(std()); eq(List.of(1L, 3L, 2L, 4L), rank(500), "aged batch jobs overtake deadlines"); });
        test("E-RK-04 equal urgency ties break by ID ascending", () -> {
            fresh(std()); eq(List.of(2L, 4L, 1L, 3L), rank(10), "deadlines tie at 1000 -> 2,4");
            fresh(new BatchWorkload(9, 1, 1, 1, 0), new BatchWorkload(7, 1, 1, 1, 0), new BatchWorkload(8, 1, 1, 1, 0));
            eq(List.of(7L, 8L, 9L), rank(0), "identical urgency -> id asc"); });
        test("E-RK-05 urgency(id, nowTick) returns the job's urgency", () -> {
            fresh(std()); eq(990, svc.urgency(2, 0), "workload 2 at 0"); eq(100, svc.urgency(1, 0), "workload 1 at 0"); eq(120, svc.urgency(1, 10), "workload 1 at 10"); });
        test("E-RK-06 urgency of an unknown id raises WorkloadNotFoundException", () -> {
            fresh(std()); throwsA(WorkloadNotFoundException.class, "id 999", () -> svc.urgency(999, 0)); });
        test("E-RK-07 repository seeds the four paper workloads", () -> {
            WorkloadRepository r = new WorkloadRepository();
            eq(4, r.all().size(), "count");
            Workload w2 = r.find(2), w4 = r.find(4);
            isTrue(w2 != null && w2.getClass().getSimpleName().equals("DeadlineWorkload"), "2 must be a DeadlineWorkload");
            eq(2, w2.latestStartTick(), "workload 2 latest start"); eq(3, r.find(4).latestStartTick(), "workload 4 latest start");
            isTrue(r.find(1) instanceof BatchWorkload && r.find(3) instanceof BatchWorkload, "1 and 3 stay BatchWorkloads"); });
        // ---- preview scheduling (Task 3) ----
        test("E-PV-01 preview validates every range with HTTP-400-style IllegalArgumentException", () -> {
            fresh(std());
            for (PlanRequest bad : List.of(req(-1, 6, 6, 10000), req(1_000_001, 6, 6, 10000), req(0, 0, 6, 10000), req(0, 25, 6, 10000),
                                           req(0, 6, 0, 10000), req(0, 6, 65, 10000), req(0, 6, 6, 0), req(0, 6, 6, 1_000_001)))
                throwsA(IllegalArgumentException.class, bad.toString(), () -> svc.preview(bad)); });
        test("E-PV-02 preview accepts the boundary values of every range", () -> {
            fresh(std());
            svc.preview(req(0, 1, 1, 1)); svc.preview(req(1_000_000, 24, 64, 1_000_000)); svc.preview(req(0, 24, 64, 1_000_000)); });
        test("E-PV-03 paper example plan: all four scheduled on half-open intervals", () -> {
            fresh(std());
            SchedulePlan p = svc.preview(req(0, 6, 6, 10000));
            eq("2[0,2) 4[2,5) 1[0,3) 3[3,5)", sel(p), "selected (ranked order, earliest feasible start)"); eq("", rej(p), "rejected");
            eq(new Reservation(2, 0, 2, 4, 6000), p.selected().get(0), "reservation record fields"); eq(0, p.nowTick(), "plan nowTick"); eq(6, p.horizon(), "plan horizon"); });
        test("E-PV-04 CPU capacity 4: jobs 1 and 3 find no slot", () -> {
            fresh(std()); SchedulePlan p = svc.preview(req(0, 6, 4, 10000));
            eq("2[0,2) 4[2,5)", sel(p), "selected"); eq("1:NO_SLOT 3:NO_SLOT", rej(p), "rejected"); });
        test("E-PV-05 CPU capacity 2: jobs larger than the cluster are EXCEEDS_CAPACITY", () -> {
            fresh(std()); SchedulePlan p = svc.preview(req(0, 6, 2, 10000));
            eq("1[0,3) 3[3,5)", sel(p), "selected"); eq("2:EXCEEDS_CAPACITY 4:EXCEEDS_CAPACITY", rej(p), "rejected in ranked order"); });
        test("E-PV-06 CPU is checked on EVERY tick, not only at the start tick", () -> {
            fresh(std()); SchedulePlan p = svc.preview(req(0, 6, 3, 10000));
            eq("4[1,4) 3[4,6)", sel(p), "job 1 must not be placed at tick 0 where it would overlap job 4"); eq("2:EXCEEDS_CAPACITY 1:NO_SLOT", rej(p), "rejected"); });
        test("E-PV-07 memory is a second capacity dimension, equal-to-capacity is allowed", () -> {
            fresh(std()); SchedulePlan p = svc.preview(req(0, 6, 64, 6000));
            eq("2[0,2) 4[2,5)", sel(p), "selected"); eq("1:NO_SLOT 3:NO_SLOT", rej(p), "rejected"); });
        test("E-PV-08 deadline: a job that cannot start by its latest start tick is DEADLINE-rejected", () -> {
            fresh(std()); SchedulePlan p = svc.preview(req(3, 6, 6, 10000));
            eq("4[3,6) 1[3,6) 3[6,8)", sel(p), "selected"); eq("2:DEADLINE", rej(p), "rejected"); });
        test("E-PV-09 release time: start >= release; release beyond the window is RELEASE_OUTSIDE_WINDOW", () -> {
            fresh(new BatchWorkload(8, 1, 1, 1, 3), new BatchWorkload(9, 1, 1, 1, 50));
            SchedulePlan p = svc.preview(req(0, 6, 4, 1000));
            eq("8[3,4)", sel(p), "job 8 starts at its release tick"); eq("9:RELEASE_OUTSIDE_WINDOW", rej(p), "job 9"); });
        test("E-PV-10 job must finish within the horizon (end may equal now+horizon)", () -> {
            fresh(new BatchWorkload(7, 1, 1, 3, 0));
            eq("7[0,3)", sel(svc.preview(req(0, 3, 4, 1000))), "fits exactly");
            eq("", sel(svc.preview(req(0, 2, 4, 1000))), "3-tick job cannot fit a 2-tick horizon"); });
        test("E-PV-11 half-open intervals: a job may start on the tick another ends", () -> {
            fresh(new BatchWorkload(1, 1, 1, 2, 0), new BatchWorkload(2, 1, 1, 2, 0));
            eq("1[0,2) 2[2,4)", sel(svc.preview(req(0, 6, 1, 10))), "second job starts at 2, not 3"); });
        test("E-PV-12 preview is read-only and repeatable", () -> {
            fresh(std());
            SchedulePlan p1 = svc.preview(req(0, 6, 6, 10000)), p2 = svc.preview(req(0, 6, 6, 10000)), p3 = svc.preview(req(0, 6, 6, 10000));
            eq(p1, p2, "second preview"); eq(p1, p3, "third preview"); eq(0, svc.reservations().size(), "no confirmed reservation created"); });
        // ---- commit, idempotency, conflicts (Task 4) ----
        test("E-CM-01 first commit stores the selected reservations", () -> {
            fresh(std());
            SchedulePlan p = svc.commit(new CommitRequest("trial-1", 0, 6, 6, 10000));
            eq("2[0,2) 4[2,5) 1[0,3) 3[3,5)", sel(p), "plan"); eq(4, svc.reservations().size(), "confirmed count");
            Reservation r1 = svc.reservations().stream().filter(r -> r.id() == 1).findFirst().orElseThrow();
            eq(new Reservation(1, 0, 3, 2, 4000), r1, "stored reservation for job 1"); });
        test("E-CM-02 identical retry returns the original plan and never double-books", () -> {
            fresh(std());
            SchedulePlan first = svc.commit(new CommitRequest("trial-1", 0, 6, 6, 10000));
            SchedulePlan retry = svc.commit(new CommitRequest("trial-1", 0, 6, 6, 10000));
            eq(first, retry, "retry plan identical"); eq(4, svc.reservations().size(), "no duplicates");
            svc.commit(new CommitRequest("trial-1", 0, 6, 6, 10000)); eq(4, svc.reservations().size(), "still 4 after another retry"); });
        test("E-CM-03 same runKey with different values raises CommitConflictException and changes nothing", () -> {
            fresh(std()); svc.commit(new CommitRequest("trial-1", 0, 6, 6, 10000));
            throwsA(CommitConflictException.class, "horizon changed", () -> svc.commit(new CommitRequest("trial-1", 0, 5, 6, 10000)));
            throwsA(CommitConflictException.class, "cpu changed", () -> svc.commit(new CommitRequest("trial-1", 0, 6, 5, 10000)));
            eq(4, svc.reservations().size(), "unchanged"); });
        test("E-CM-04 a new runKey sees the confirmed reservations (no double-booking across runs)", () -> {
            fresh(std()); svc.commit(new CommitRequest("trial-1", 0, 6, 6, 10000));
            SchedulePlan p = svc.preview(req(0, 6, 6, 10000));
            eq("", sel(p), "capacity already consumed by trial-1"); eq("2:NO_SLOT 4:NO_SLOT 1:NO_SLOT 3:NO_SLOT", rej(p), "all rejected");
            SchedulePlan second = svc.commit(new CommitRequest("trial-2", 0, 6, 6, 10000));
            eq("", sel(second), "trial-2 selects nothing"); eq(4, svc.reservations().size(), "still 4"); });
        test("E-CM-05 invalid commits are rejected, persist nothing and do not burn the runKey", () -> {
            fresh(std());
            throwsA(IllegalArgumentException.class, "horizon 0", () -> svc.commit(new CommitRequest("k", 0, 0, 6, 10000)));
            throwsA(IllegalArgumentException.class, "cpu 65", () -> svc.commit(new CommitRequest("k", 0, 6, 65, 10000)));
            throwsA(IllegalArgumentException.class, "blank key", () -> svc.commit(new CommitRequest("  ", 0, 6, 6, 10000)));
            eq(0, svc.reservations().size(), "nothing persisted");
            eq(4, svc.commit(new CommitRequest("k", 0, 6, 6, 10000)).selected().size(), "valid commit with the same key still works"); });
        test("E-CM-06 reservations() is complete and deterministic", () -> {
            fresh(std()); svc.commit(new CommitRequest("trial-1", 0, 6, 6, 10000));
            List<Reservation> r1 = svc.reservations(), r2 = svc.reservations();
            eq(r1, r2, "stable order across calls");
            eq(Set.of(new Reservation(2, 0, 2, 4, 6000), new Reservation(4, 2, 5, 3, 6000), new Reservation(1, 0, 3, 2, 4000), new Reservation(3, 3, 5, 2, 2000)), new HashSet<>(r1), "exact set"); });
        test("E-CM-07 a confirmed reservation ends at its exclusive end tick: the next run may start exactly there", () -> {
            fresh(new BatchWorkload(1, 1, 1, 2, 0), new BatchWorkload(2, 1, 1, 2, 0));
            eq("1[0,2)", sel(svc.commit(new CommitRequest("a", 0, 2, 1, 10))), "first run books ticks 0 and 1");
            eq("1[2,4) 2[4,6)", sel(svc.preview(req(2, 4, 1, 10))), "tick 2 is free again (confirmed interval is half-open)"); });
        // ---- error mapping ----
        test("E-ER-01 unknown workload -> HTTP 404 ApiError NOT_FOUND", () -> {
            fresh(std()); var r = mvc.get("/api/workloads/999/urgency?nowTick=0"); eq(404, r.status(), "status");
            eq("NOT_FOUND", mvc.json().readTree(r.body()).path("code").asText(), "code"); });
        test("E-ER-02 invalid input -> HTTP 400 ApiError BAD_REQUEST", () -> {
            fresh(std()); var r = mvc.post("/api/workloads/preview", "{\"nowTick\":0,\"horizon\":25,\"cpuCapacity\":6,\"memoryCapacity\":10000}"); eq(400, r.status(), "status");
            JsonNode j = mvc.json().readTree(r.body()); eq("BAD_REQUEST", j.path("code").asText(), "code"); isTrue(!j.path("message").asText().isEmpty(), "message"); });
        test("E-ER-03 changed commit on a reused runKey -> HTTP 409 ApiError CONFLICT", () -> {
            fresh(std()); mvc.post("/api/workloads/commit", commit("trial-1", 6));
            var r = mvc.post("/api/workloads/commit", commit("trial-1", 5)); eq(409, r.status(), "status");
            eq("CONFLICT", mvc.json().readTree(r.body()).path("code").asText(), "code"); });
        // ---- REST endpoints ----
        test("E-HT-01 GET /api/workloads/2/urgency?nowTick=0 -> 990", () -> {
            fresh(std()); var r = mvc.get("/api/workloads/2/urgency?nowTick=0"); eq(200, r.status(), "status");
            eq(990, urgencyValue(mvc.json().readTree(r.body())), "urgency"); });
        test("E-HT-02 GET /api/workloads/ranked?nowTick=0 -> ids [2,4,1,3]", () -> {
            fresh(std()); var r = mvc.get("/api/workloads/ranked?nowTick=0"); eq(200, r.status(), "status");
            List<Long> ids = new ArrayList<>(); for (JsonNode n : mvc.json().readTree(r.body())) ids.add(n.path("id").asLong());
            eq(List.of(2L, 4L, 1L, 3L), ids, "ids"); });
        test("E-HT-03 POST /api/workloads/preview -> the paper example plan as JSON", () -> {
            fresh(std()); var r = mvc.post("/api/workloads/preview", PREVIEW); eq(200, r.status(), "status");
            JsonNode j = mvc.json().readTree(r.body()); eq(4, j.path("selected").size(), "selected size"); eq(0, j.path("rejected").size(), "rejected size");
            JsonNode s0 = j.path("selected").get(0); eq(2, s0.path("id").asInt(), "id"); eq(0, s0.path("startTick").asInt(), "start"); eq(2, s0.path("endTickExclusive").asInt(), "end");
            eq(4, s0.path("cpuCores").asInt(), "cpu"); eq(6000, s0.path("memoryMb").asInt(), "mem"); });
        test("E-HT-04 POST /api/workloads/commit stores reservations visible in GET /reservations", () -> {
            fresh(std()); var r = mvc.post("/api/workloads/commit", commit("trial-1", 6));
            isTrue(r.status() == 200 || r.status() == 201, "status was " + r.status());
            eq(4, mvc.json().readTree(r.body()).path("selected").size(), "plan selected");
            eq(4, mvc.json().readTree(mvc.get("/api/workloads/reservations").body()).size(), "reservations"); });
        test("E-HT-05 identical commit retried over HTTP returns the same plan and no duplicates", () -> {
            fresh(std()); var r1 = mvc.post("/api/workloads/commit", commit("trial-1", 6)); var r2 = mvc.post("/api/workloads/commit", commit("trial-1", 6));
            eq(r1.status(), r2.status(), "status"); eq(mvc.json().readTree(r1.body()), mvc.json().readTree(r2.body()), "body");
            eq(4, mvc.json().readTree(mvc.get("/api/workloads/reservations").body()).size(), "reservations"); });
        test("E-HT-06 unknown id -> 404 and invalid ranked/urgency input -> 400 over HTTP", () -> {
            fresh(std()); eq(404, mvc.get("/api/workloads/999/urgency?nowTick=0").status(), "unknown id");
            eq(400, mvc.get("/api/workloads/ranked?nowTick=-1").status(), "negative nowTick");
            eq(400, mvc.post("/api/workloads/commit", "{\"runKey\":\"x\",\"nowTick\":0,\"horizon\":0,\"cpuCapacity\":6,\"memoryCapacity\":10000}").status(), "invalid commit"); });
        test("E-HT-07 repeated previews over HTTP leave GET /reservations empty", () -> {
            fresh(std()); mvc.post("/api/workloads/preview", PREVIEW); mvc.post("/api/workloads/preview", PREVIEW);
            eq(0, mvc.json().readTree(mvc.get("/api/workloads/reservations").body()).size(), "no reservations"); });
        test("E-HT-08 GET /api/workloads/reservations is deterministic across calls", () -> {
            fresh(std()); mvc.post("/api/workloads/commit", commit("trial-1", 6));
            eq(mvc.get("/api/workloads/reservations").body(), mvc.get("/api/workloads/reservations").body(), "same body twice"); });
        // ---- structural ----
        test("E-ST-01 scheduling code does not branch on concrete workload types (instanceof)", () -> {
            String src = source("edu/practice/scheduler/service/SchedulerService.java");
            isTrue(!src.isEmpty(), "SchedulerService.java not found"); isTrue(!src.contains("instanceof"), "SchedulerService uses instanceof");
            fresh(std()); isTrue(svc.preview(req(0, 6, 6, 10000)).selected().size() == 4, "preview must be implemented"); });
    }
}
