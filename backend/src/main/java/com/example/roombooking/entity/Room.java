package com.example.roombooking.entity;

import jakarta.persistence.*;
import lombok.Data;
import java.util.Set;

@Entity
@Table(name = "rooms")
@Data
public class Room {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "room_id")
    private Long id;
    
    @Column(name = "room_name")
    private String name;
    
    private Integer capacity;
    
    private String location;
    
    private Boolean available;
    
    private Boolean restricted;
    
    @OneToMany(mappedBy = "room")
    private Set<RoomEquipment> equipment;
    
    @OneToMany(mappedBy = "room")
    private Set<Booking> bookings;
    
    @OneToMany(mappedBy = "room")
    private Set<Schedule> schedules;
}