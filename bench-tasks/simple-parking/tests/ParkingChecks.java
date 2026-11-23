package bench;

import com.fasterxml.jackson.databind.JsonNode;
import edu.practice.parking.controller.ParkingController;
import edu.practice.parking.dto.NewHourlyPass;
import edu.practice.parking.dto.Quote;
import edu.practice.parking.error.ApiExceptionHandler;
import edu.practice.parking.error.PassNotFoundException;
import edu.practice.parking.model.*;
import edu.practice.parking.repo.PassRepository;
import edu.practice.parking.service.ParkingService;

import java.util.List;

import static bench.Check.*;

/**
 * SIMPLE — Parking Access & Fee Quotation API.
 * Every expected value below comes from SIMPLE_Practice_Paper.docx (formulas and the
 * "illustrative calculations"), never from a generated solution. Test ids are
 * referenced by requirement id in task.json ("tests": [...]).
 */
public class ParkingChecks {
    static final String WEEKEND = "edu.practice.parking.model.WeekendPass";
    static PassRepository repo; static ParkingService svc; static MiniMvc mvc; static int base;

    /** Fresh state per test; passes are saved explicitly so tests do not depend on the solution's seed. */
    static void fresh(boolean withWeekend) throws Exception {
        repo = new PassRepository();
        repo.save(new HourlyPass(1, "CAR-101", 250));
        if (withWeekend) repo.save((ParkingPass) make(WEEKEND, 2L, "VAN-202", 800));
        svc = new ParkingService(repo);
        mvc = new MiniMvc(new ParkingController(svc), new ApiExceptionHandler());
        base = repo.all().size();   // whatever the solution seeded + what we saved; counts below are relative to it
    }
    static ParkingPass weekend(long id, int flat) throws Exception { return (ParkingPass) make(WEEKEND, id, "W-" + id, flat); }

    public static void main(String[] a) {
        // ---- R1 HourlyPass: ceiling-division pricing (paper Task 1, 6+4 marks) ----
        test("S-HP-01 hourly 1..60 min = one hour", () -> {
            ParkingPass p = new HourlyPass(1, "X", 250);
            eq(250, p.priceCents(1), "1 min"); eq(250, p.priceCents(59), "59 min"); eq(250, p.priceCents(60), "60 min"); });
        test("S-HP-02 hourly 61 min = 2 hours (paper example 500)", () -> {
            ParkingPass p = new HourlyPass(1, "X", 250);
            eq(500, p.priceCents(61), "61 min"); eq(500, p.priceCents(120), "120 min"); eq(750, p.priceCents(121), "121 min"); });
        test("S-HP-03 hourly price scales with the pass's own rate", () -> {
            eq(1200, new HourlyPass(5, "Y", 300).priceCents(181), "181 min = 4 billable hours x 300"); });
        // ---- R2 HourlyPass validation (Task 1, 4 marks) ----
        test("S-HP-04 hourly rejects zero and negative stays", () -> {
            ParkingPass p = new HourlyPass(1, "X", 250);
            throwsA(IllegalArgumentException.class, "0 min", () -> p.priceCents(0));
            throwsA(IllegalArgumentException.class, "-1 min", () -> p.priceCents(-1));
            throwsA(IllegalArgumentException.class, "MIN_VALUE", () -> p.priceCents(Integer.MIN_VALUE)); });
        test("S-HP-05 hourly never returns an overflowed price", () -> {
            ParkingPass p = new HourlyPass(1, "X", 250);
            eq(250, p.priceCents(60), "baseline must work first");
            try { int v = p.priceCents(Integer.MAX_VALUE); throw new AssertionError("returned " + v + " instead of rejecting an overflowing price"); }
            catch (RuntimeException expected) { /* any rejection is acceptable */ } });
        test("S-HP-06 HourlyPass keeps inheritance, getter and final rate field", () -> {
            isTrue(ParkingPass.class.isAssignableFrom(HourlyPass.class), "extends ParkingPass");
            eq(250, new HourlyPass(1, "X", 250).getRateCents(), "getRateCents");
            var f = HourlyPass.class.getDeclaredField("rateCents");
            isTrue(java.lang.reflect.Modifier.isFinal(f.getModifiers()), "rateCents must be final"); });
        // ---- R3/R4 WeekendPass (Task 2) ----
        test("S-WP-01 WeekendPass exists, extends ParkingPass, exposes getFlatCents", () -> {
            Object w = make(WEEKEND, 2L, "VAN-202", 800);
            isTrue(w instanceof ParkingPass, "extends ParkingPass");
            eq(800, w.getClass().getMethod("getFlatCents").invoke(w), "getFlatCents");
            eq(2L, ((ParkingPass) w).getId(), "id via parent constructor"); eq("VAN-202", ((ParkingPass) w).getRegistration(), "registration"); });
        test("S-WP-02 weekend flat price for 1..480 minutes (paper: 480 -> 800)", () -> {
            ParkingPass w = weekend(2, 800);
            eq(800, w.priceCents(1), "1"); eq(800, w.priceCents(479), "479"); eq(800, w.priceCents(480), "480"); });
        test("S-WP-03 weekend adds 150 per commenced extra hour (paper: 481 -> 950)", () -> {
            ParkingPass w = weekend(2, 800);
            eq(950, w.priceCents(481), "481"); eq(950, w.priceCents(540), "540 = exactly 1 extra hour");
            eq(1100, w.priceCents(541), "541"); eq(1250, w.priceCents(601), "601 = 3 extra hours"); });
        test("S-WP-04 weekend rejects non-positive stays", () -> {
            ParkingPass w = weekend(2, 800);
            throwsA(IllegalArgumentException.class, "0", () -> w.priceCents(0));
            throwsA(IllegalArgumentException.class, "-5", () -> w.priceCents(-5)); });
        test("S-WP-05 repository seeds WeekendPass(2, VAN-202, 800)", () -> {
            PassRepository r = new PassRepository();
            ParkingPass w = r.get(2);
            isTrue(w != null && w.getClass().getSimpleName().equals("WeekendPass"), "id 2 must be a WeekendPass");
            eq("VAN-202", w.getRegistration(), "registration"); eq(800, w.priceCents(60), "flat price");
            ParkingPass h = r.get(1); isTrue(h instanceof HourlyPass, "id 1 stays an HourlyPass"); });
        // ---- R5 allQuotes: polymorphic + deterministic order (Task 2, 8 marks) ----
        test("S-Q-01 allQuotes at 481 min: weekend 950 before hourly 2250 (paper example)", () -> {
            fresh(true);
            List<Quote> q = svc.allQuotes(481);
            eq(2, q.size(), "size"); eq(2L, q.get(0).id(), "first id"); eq(950, q.get(0).priceCents(), "first price");
            eq(1L, q.get(1).id(), "second id"); eq(2250, q.get(1).priceCents(), "second price"); });
        test("S-Q-02 allQuotes at 61 min sorted ascending (hourly 500, weekend 800)", () -> {
            fresh(true);
            List<Quote> q = svc.allQuotes(61);
            eq(1L, q.get(0).id(), "first"); eq(500, q.get(0).priceCents(), "p1"); eq(2L, q.get(1).id(), "second"); eq(800, q.get(1).priceCents(), "p2"); });
        test("S-Q-03 equal prices are ordered by ID ascending", () -> {
            fresh(true);
            repo.save(new HourlyPass(9, "TIE-9", 400)); repo.save(new HourlyPass(3, "TIE-3", 400));
            List<Quote> q = svc.allQuotes(120);   // 800, 800, 800 for ids 2,3,9 ; id1 = 500
            eq(List.of(1L, 2L, 3L, 9L), q.stream().map(Quote::id).toList(), "order"); });
        test("S-Q-04 quote fields carry stay and price", () -> {
            fresh(true);
            Quote q = svc.quote(1, 61);
            eq(1L, q.id(), "id"); eq("CAR-101", q.registration(), "registration"); eq(61, q.stayMinutes(), "stayMinutes"); eq(500, q.priceCents(), "price"); });
        test("S-Q-05 allQuotes does not branch on concrete pass types (instanceof)", () -> {
            String src = source("edu/practice/parking/service/ParkingService.java");
            isTrue(!src.isEmpty(), "ParkingService.java not found");
            isTrue(!src.contains("instanceof"), "ParkingService uses instanceof");
            fresh(true); isTrue(svc.allQuotes(60).size() == 2, "allQuotes must be implemented and return every pass"); });
        test("S-Q-06 allQuotes rejects non-positive minutes", () -> {
            fresh(true);
            throwsA(IllegalArgumentException.class, "0", () -> svc.allQuotes(0));
            throwsA(IllegalArgumentException.class, "-1", () -> svc.allQuotes(-1)); });
        // ---- R6/R7 service quote validation + 404 (Task 3) ----
        test("S-SV-01 quote validates positive minutes", () -> {
            fresh(false);
            throwsA(IllegalArgumentException.class, "0", () -> svc.quote(1, 0));
            throwsA(IllegalArgumentException.class, "-30", () -> svc.quote(1, -30)); });
        test("S-SV-02 quote of a missing id raises PassNotFoundException", () -> {
            fresh(false);
            throwsA(PassNotFoundException.class, "id 99", () -> svc.quote(99, 60)); });
        // ---- R8 addHourly validation (Task 3, 6 marks) ----
        test("S-SV-03 addHourly stores a valid pass and trims the registration", () -> {
            fresh(false);
            ParkingPass p = svc.addHourly(new NewHourlyPass(3, "  CAR-303  ", 300));
            eq("CAR-303", p.getRegistration(), "returned registration trimmed");
            eq("CAR-303", repo.get(3).getRegistration(), "stored registration trimmed");
            eq(300, ((HourlyPass) repo.get(3)).getRateCents(), "rate"); });
        test("S-SV-04 addHourly rejects non-positive id and persists nothing", () -> {
            fresh(false);
            throwsA(IllegalArgumentException.class, "id 0", () -> svc.addHourly(new NewHourlyPass(0, "A", 100)));
            throwsA(IllegalArgumentException.class, "id -4", () -> svc.addHourly(new NewHourlyPass(-4, "A", 100)));
            eq(base, repo.all().size(), "nothing added"); });
        test("S-SV-05 addHourly rejects a duplicate id and keeps the original", () -> {
            fresh(false);
            throwsA(IllegalArgumentException.class, "dup", () -> svc.addHourly(new NewHourlyPass(1, "OTHER", 999)));
            eq("CAR-101", repo.get(1).getRegistration(), "original untouched"); });
        test("S-SV-06 addHourly rejects blank or missing registration", () -> {
            fresh(false);
            throwsA(IllegalArgumentException.class, "blank", () -> svc.addHourly(new NewHourlyPass(5, "   ", 100)));
            throwsA(IllegalArgumentException.class, "empty", () -> svc.addHourly(new NewHourlyPass(5, "", 100)));
            throwsA(IllegalArgumentException.class, "null", () -> svc.addHourly(new NewHourlyPass(5, null, 100)));
            eq(base, repo.all().size(), "nothing added"); });
        test("S-SV-07 addHourly rejects non-positive hourly rate", () -> {
            fresh(false);
            throwsA(IllegalArgumentException.class, "rate 0", () -> svc.addHourly(new NewHourlyPass(5, "A", 0)));
            throwsA(IllegalArgumentException.class, "rate -1", () -> svc.addHourly(new NewHourlyPass(5, "A", -1)));
            eq(base, repo.all().size(), "nothing added"); });
        // ---- R9 error mapping (Task 3, 6+4 marks) ----
        test("S-ER-01 missing pass -> HTTP 404 with ApiError code NOT_FOUND", () -> {
            fresh(false);
            var r = mvc.get("/api/passes/99/quote?minutes=60");
            eq(404, r.status(), "status"); JsonNode j = mvc.json().readTree(r.body());
            eq("NOT_FOUND", j.path("code").asText(), "code"); isTrue(!j.path("message").asText().isEmpty(), "message present"); });
        test("S-ER-02 invalid input -> HTTP 400 with ApiError code BAD_REQUEST", () -> {
            fresh(false);
            var r = mvc.get("/api/passes/1/quote?minutes=0");
            eq(400, r.status(), "status"); JsonNode j = mvc.json().readTree(r.body());
            eq("BAD_REQUEST", j.path("code").asText(), "code"); isTrue(!j.path("message").asText().isEmpty(), "message present"); });
        // ---- R10-R13 REST endpoints (Task 4 + Section B) ----
        test("S-HT-01 GET /api/passes/1/quote?minutes=61 -> 200 Quote(500)", () -> {
            fresh(false);
            var r = mvc.get("/api/passes/1/quote?minutes=61");
            eq(200, r.status(), "status"); JsonNode j = mvc.json().readTree(r.body());
            eq(1, j.path("id").asInt(), "id"); eq(500, j.path("priceCents").asInt(), "priceCents"); eq(61, j.path("stayMinutes").asInt(), "stayMinutes"); });
        test("S-HT-02 GET /api/passes/quotes?minutes=481 -> sorted [2 (950), 1 (2250)]", () -> {
            fresh(true);
            var r = mvc.get("/api/passes/quotes?minutes=481");
            eq(200, r.status(), "status"); JsonNode j = mvc.json().readTree(r.body());
            eq(2, j.size(), "size"); eq(2, j.get(0).path("id").asInt(), "first id"); eq(950, j.get(0).path("priceCents").asInt(), "first price");
            eq(1, j.get(1).path("id").asInt(), "second id"); eq(2250, j.get(1).path("priceCents").asInt(), "second price"); });
        test("S-HT-03 GET /api/passes/quotes?minutes=61 returns ascending charges", () -> {
            fresh(true);
            JsonNode j = mvc.json().readTree(mvc.get("/api/passes/quotes?minutes=61").body());
            eq(500, j.get(0).path("priceCents").asInt(), "first"); eq(800, j.get(1).path("priceCents").asInt(), "second"); });
        test("S-HT-04 POST /api/passes/hourly -> 201 with the created pass", () -> {
            fresh(false);
            var r = mvc.post("/api/passes/hourly", "{\"id\":3,\"registration\":\"CAR-303\",\"rateCents\":300}");
            eq(201, r.status(), "status"); JsonNode j = mvc.json().readTree(r.body());
            eq(3, j.path("id").asInt(), "id"); eq("CAR-303", j.path("registration").asText(), "registration"); eq(300, j.path("rateCents").asInt(), "rateCents"); });
        test("S-HT-05 a created pass appears in GET /api/passes and can be quoted", () -> {
            fresh(false);
            eq(201, mvc.post("/api/passes/hourly", "{\"id\":3,\"registration\":\"CAR-303\",\"rateCents\":300}").status(), "post");
            JsonNode list = mvc.json().readTree(mvc.get("/api/passes").body());
            eq(base + 1, list.size(), "list size");
            JsonNode q = mvc.json().readTree(mvc.get("/api/passes/3/quote?minutes=61").body());
            eq(600, q.path("priceCents").asInt(), "quote of new pass (2 h x 300)"); });
        test("S-HT-06 invalid POST payload -> 400 and nothing persisted", () -> {
            fresh(false);
            eq(400, mvc.post("/api/passes/hourly", "{\"id\":3,\"registration\":\"   \",\"rateCents\":300}").status(), "blank registration");
            eq(400, mvc.post("/api/passes/hourly", "{\"id\":3,\"registration\":\"A\",\"rateCents\":0}").status(), "zero rate");
            eq(400, mvc.post("/api/passes/hourly", "{\"id\":1,\"registration\":\"A\",\"rateCents\":100}").status(), "duplicate id");
            eq(base, repo.all().size(), "no pass persisted"); });
        test("S-HT-07 invalid stay minutes via HTTP -> 400 (quotes and single quote)", () -> {
            fresh(true);
            eq(400, mvc.get("/api/passes/quotes?minutes=0").status(), "quotes minutes=0");
            eq(400, mvc.get("/api/passes/2/quote?minutes=-5").status(), "quote minutes=-5"); });
        test("S-HT-08 GET /api/passes lists the seeded passes", () -> {
            fresh(true);
            eq(2, mvc.json().readTree(mvc.get("/api/passes").body()).size(), "list size"); });
    }
}
