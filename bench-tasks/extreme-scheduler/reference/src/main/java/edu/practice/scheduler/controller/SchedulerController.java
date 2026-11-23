package edu.practice.scheduler.controller;
import edu.practice.scheduler.service.*;import edu.practice.scheduler.model.*;import edu.practice.scheduler.dto.*;
import java.util.*;import org.springframework.web.bind.annotation.*;
@RestController @RequestMapping("/api/workloads") public class SchedulerController {
 private final SchedulerService service;
 public SchedulerController(SchedulerService service){this.service=service;}
 @GetMapping public Collection<Workload> all(){return service.all();}
 @GetMapping("/{id}/urgency") public Map<String,Integer> urgency(@PathVariable long id,@RequestParam int nowTick){return Map.of("urgency",service.urgency(id,nowTick));}
 @GetMapping("/ranked") public List<Workload> ranked(@RequestParam int nowTick){return service.ranked(nowTick);}
 @PostMapping("/preview") public SchedulePlan preview(@RequestBody PlanRequest request){return service.preview(request);}
 @PostMapping("/commit") public SchedulePlan commit(@RequestBody CommitRequest request){return service.commit(request);}
 @GetMapping("/reservations") public List<Reservation> reservations(){return service.reservations();}
}
