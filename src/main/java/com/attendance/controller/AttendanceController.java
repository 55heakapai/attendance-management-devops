package com.attendance.controller;

import com.attendance.model.AttendanceRecord;
import com.attendance.model.CheckInRequest;
import com.attendance.model.StatusResponse;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CopyOnWriteArrayList;

@RestController
@RequestMapping("/attendance")
@CrossOrigin(origins = "*")
public class AttendanceController {

    private final List<AttendanceRecord> records = new CopyOnWriteArrayList<>();

    @GetMapping("/status")
    public ResponseEntity<StatusResponse> getStatus() {
        StatusResponse response = new StatusResponse(
            "UP",
            "Attendance Management Service is running",
            LocalDateTime.now().toString(),
            records.size()
        );
        return ResponseEntity.ok(response);
    }

    @PostMapping("/checkin")
    public ResponseEntity<AttendanceRecord> checkIn(@RequestBody CheckInRequest request) {
        AttendanceRecord record = new AttendanceRecord(
            UUID.randomUUID().toString(),
            request.getUserId(),
            request.getUserName(),
            LocalDateTime.now().toString(),
            "CHECKED_IN",
            request.getLocation()
        );
        records.add(record);
        return ResponseEntity.ok(record);
    }

    @GetMapping("/records")
    public ResponseEntity<List<AttendanceRecord>> getAllRecords() {
        return ResponseEntity.ok(new ArrayList<>(records));
    }
}
