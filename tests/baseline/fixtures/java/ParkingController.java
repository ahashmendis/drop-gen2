package edu.practice.parking.controller;
import edu.practice.parking.service.*;import edu.practice.parking.model.*;import edu.practice.parking.dto.*;
import java.util.*;import org.springframework.http.*;import org.springframework.web.bind.annotation.*;
@RestController @RequestMapping("/api/passes") public class ParkingController {
 private final ParkingService service;
 public ParkingController(ParkingService service){this.service=service;}
 @GetMapping public Collection<ParkingPass> list(){return service.all();}
 @GetMapping("/{id}/quote") public Quote quote(@PathVariable long id,@RequestParam int minutes){return service.quote(id,minutes);}
 @GetMapping("/quotes") public List<Quote> quotes(@RequestParam int minutes){return service.allQuotes(minutes);}
 @PostMapping("/hourly") public ResponseEntity<ParkingPass> addHourly(@RequestBody NewHourlyPass body){
  return ResponseEntity.status(HttpStatus.CREATED).body(service.addHourly(body));
 }
}
