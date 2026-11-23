package edu.practice.dispatch.controller;
import edu.practice.dispatch.service.*;import edu.practice.dispatch.model.*;import edu.practice.dispatch.dto.*;
import java.util.*;import org.springframework.web.bind.annotation.*;import org.springframework.http.*;
@RestController @RequestMapping("/api/missions") public class DispatchController {
 private final DispatchService service;
 public DispatchController(DispatchService service){this.service=service;}
 @GetMapping public Collection<DispatchMission> all(){return service.all();}
 @GetMapping("/{id}/energy") public Map<String,Integer> energy(@PathVariable long id){return Map.of("energyUnits",service.energy(id));}
 @PostMapping("/air") public ResponseEntity<DispatchMission> addAir(@RequestBody NewAirMission body){
  return ResponseEntity.status(HttpStatus.CREATED).body(service.addAir(body));
 }
 @GetMapping("/plan") public DispatchPlan plan(@RequestParam int capacity,@RequestParam(defaultValue="false") boolean urgentOnly){
  return service.plan(capacity,urgentOnly);
 }
}
