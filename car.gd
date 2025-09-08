extends CharacterBody2D

const FWD := Vector2.UP              # sprite points up
@export var accel: float = 600.0
@export var max_speed: float = 450.0
@export var reverse_accel: float = 350.0
@export var reverse_max_speed: float = 200.0
@export var brake_decel: float = 1600.0
@export var friction_coast: float = 800.0
@export var steer_speed: float = 2.8
@export var steer_min_factor: float = 0.25
@export var steer_sign: float = 1.0  # set to -1 if you still feel it’s inverted
@export var control_enabled: bool = true

var speed: float = 0.0

func _physics_process(delta: float) -> void:
	if not control_enabled:
		velocity = Vector2.ZERO
		move_and_slide()
		return
	
	
	var gas: float = Input.get_action_strength("throttle")
	var brk: float = Input.get_action_strength("brake")
	var steer_in: float = Input.get_action_strength("right") - Input.get_action_strength("left")

	# accel / brake / reverse
	speed += gas * accel * delta
	if brk > 0.0:
		if speed > 0.0:
			speed = max(0.0, speed - brake_decel * delta)
		else:
			speed = max(-reverse_max_speed, speed - reverse_accel * delta)
	elif is_equal_approx(gas, 0.0):
		var sgn: float = signf(speed)
		speed = sgn * max(0.0, absf(speed) - friction_coast * delta)
	speed = clampf(speed, -reverse_max_speed, max_speed)

	# steering (flip when reversing)
	var speed_norm: float = speed / max_speed if speed >= 0.0 else speed / -reverse_max_speed
	var steer_factor: float = clampf(absf(speed_norm), steer_min_factor, 1.0)

	# flip steering when moving backwards (with a small deadzone)
	var reverse_flip: float = -1.0 if speed < -1.0 else 1.0

	rotation += steer_sign * reverse_flip * steer_in * steer_speed * steer_factor * delta

	# move in facing direction (UP is forward)
	velocity = FWD.rotated(rotation) * speed
	move_and_slide()
	
	
func _ready() -> void:
	print("Car initial position:", global_position)
