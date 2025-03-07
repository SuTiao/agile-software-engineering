package com.example.roombooking.entity;

import com.fasterxml.jackson.annotation.JsonBackReference;
import jakarta.persistence.*;
import lombok.Data;

@Entity
@Table(name = "room_equipment")
@Data
public class RoomEquipment {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "equipment_id")
    private Long id;
    
    @ManyToOne
    @JoinColumn(name = "room_id")
    @JsonBackReference("room-equipment")
    private Room room;
    
    @Column(name = "equipment_name")
    private String name;
    
    private String description;
    
    @Column(name = "is_available")
    private Boolean isAvailable;
}