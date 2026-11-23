package edu.practice.parking.error;
import edu.practice.parking.dto.ApiError;import org.springframework.http.*;
import org.springframework.web.bind.annotation.*;
@RestControllerAdvice public class ApiExceptionHandler {
 @ExceptionHandler(IllegalArgumentException.class)
 public ResponseEntity<ApiError> badRequest(IllegalArgumentException e){
  return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(new ApiError("BAD_REQUEST",e.getMessage()));
 }
 @ExceptionHandler(PassNotFoundException.class)
 public ResponseEntity<ApiError> notFound(PassNotFoundException e){
  return ResponseEntity.status(HttpStatus.NOT_FOUND).body(new ApiError("NOT_FOUND",e.getMessage()));
 }
}
