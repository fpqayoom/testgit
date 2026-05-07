extends CharacterBody2D

const SPEED = 300.0
const JUMP_VELOCITY = -400.0


func _physics_process(delta: float) -> void:
	# 1. HORIZONTAL MOVEMENT
	if Input.is_action_just_pressed("desh"):
		print("desh")
		
	var direction_x := Input.get_axis("move_left", "move_right")
	if direction_x:
		velocity.x = direction_x * SPEED 
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)

	# 2. VERTICAL MOVEMENT & ANTI-GRAVITY
	var direction_y := Input.get_axis("move_up", "move_down")
	
	if direction_y != 0:
		# Flying/Climbing
		velocity.y = direction_y * SPEED
	else:
		# Normal Gravity
		if not is_on_floor():
			velocity += get_gravity() * delta
			
		# Jump (Reads the "jump" action directly from the TouchScreenButton)
		if Input.is_action_just_pressed("jump") and is_on_floor():
			velocity.y = JUMP_VELOCITY

	move_and_slide()
