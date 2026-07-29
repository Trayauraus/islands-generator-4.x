extends Node3D

#region Constants & Variables
@export_file("*.tres", "*.res") var terrain_material_file : String
@export var debug_prints := true

var rng = RandomNumberGenerator.new()

#to be used by the diamond square algorithm, array height and width must be 2^n+1
var size = 128
var mapsize = size + 1

var map = []
var width #map dimensions
var height

var chunk = size
var roughness #scope of randval
var half
var randval #random value to be added to average position

# jitter is the amount that roughness changes between recursions.
# Best values are between 2 (very rough terrain) and 3 (gently rolling hills).
var jitter = 2.2

#arrays for MeshArray generation
var vertices = PackedVector3Array()
var UVs = PackedVector2Array()
var normals = PackedVector3Array()

var height_gradient = Gradient.new() #color gradient for texturing based on height
var sand = Color(0.96,0.92,0.47)
var rock = Color(0.62,0.69,0.50)
var grass = Color(0.13,0.69,0.02)
var snow = Color(0.95,0.95,0.95)

@onready var player: CharacterBody3D = $Player
@onready var egocam: Camera3D = $Player/Egocam
@onready var camera: Camera3D = $Camera

var water_level: float = 3.0 # height of the water surface
var playerstart = Vector3(0,0,0) #player starting position
var camerastart = Vector3(0,0,0)

#endregion

#region Lifecycle

func _ready():
	
	rng.randomize()
	var seed_val: int = rng.seed
	print("Seed: ", seed_val)
	
	width = size
	height = size
	
	#creating the color gradient (offsets are 0.0-1.0 in Godot 4)
	height_gradient.set_color(0, sand)
	height_gradient.remove_point(1)
	height_gradient.add_point(0.2, sand)
	height_gradient.add_point(0.35, grass)
	height_gradient.add_point(0.55, grass)
	height_gradient.add_point(0.65, rock)
	height_gradient.add_point(0.85, rock)
	height_gradient.add_point(0.92, snow)
	height_gradient.add_point(1.0, snow)
	
	camerastart = Vector3(size * 0.5, size * 0.5 + size * 0.125, size * 0.125)
	camera.position = camerastart
	
	if OS.is_debug_build() and debug_prints: print("[DEBUG] Starting diamond-square generation (size=%d, jitter=%.1f)..." % [size, jitter])
	var time_start: int = Time.get_ticks_msec()
	diamond_square()
	var time_ds: int = Time.get_ticks_msec() - time_start
	if OS.is_debug_build() and debug_prints: print("[DEBUG] Diamond-square completed in %d ms" % time_ds)
	
	if OS.is_debug_build() and debug_prints: print("[DEBUG] Building terrain mesh...")
	var time_mesh_start: int = Time.get_ticks_msec()
	make_terrain()
	var time_mesh: int = Time.get_ticks_msec() - time_mesh_start
	if OS.is_debug_build() and debug_prints: print("[DEBUG] Terrain mesh built in %d ms" % time_mesh)
	
	#player is moved to the center of the map
	var half_idx: int = size >> 1
	playerstart = Vector3(half_idx, map[half_idx][-half_idx] + 10.0, -half_idx)
	player.position = playerstart
	
	if OS.is_debug_build() and debug_prints: print("[DEBUG] Player placed at ", playerstart)
	
#endregion

#region Input Handling

func _on_Roughness_slider_value_changed(value: float):
	jitter = value
	if OS.is_debug_build() and debug_prints: print("[DEBUG] Jitter changed to %.2f" % jitter)


func _input(event: InputEvent):
	
	
	if event.is_action_pressed("ui_focus_next"): #press Tab to toggle between cameras
		if egocam.is_current():
			camera.make_current()
			if OS.is_debug_build() and debug_prints: print("[DEBUG] Switched to overhead camera")
		else:
			egocam.make_current()
			if OS.is_debug_build() and debug_prints: print("[DEBUG] Switched to egocentric camera")

	if event.is_action_pressed("ui_select"): #press SPACE to generate islands
		
		if OS.is_debug_build() and debug_prints: print("[DEBUG] Generating new terrain...")
		rng.randomize()
		print("Seed: ", rng.seed)
		
		camerastart = Vector3(size * 0.5, size * 0.5 + size * 0.125, size * 0.125)
		camera.position = camerastart
		
		var time_start: int = Time.get_ticks_msec()
		diamond_square()
		if OS.is_debug_build() and debug_prints: print("[DEBUG] Diamond-square completed in %d ms" % [Time.get_ticks_msec() - time_start])
		
		var time_mesh_start: int = Time.get_ticks_msec()
		make_terrain()
		if OS.is_debug_build() and debug_prints: print("[DEBUG] Terrain mesh built in %d ms" % [Time.get_ticks_msec() - time_mesh_start])
		
		#player is moved to the center of the map
		var half_idx: int = size >> 1
		playerstart = Vector3(half_idx, map[half_idx][-half_idx] + 10.0, -half_idx)
		player.position = playerstart

#endregion

#region Mesh Creation

func make_terrain():
	#arrays need to be emptied. clear() does not work for some reason.
	vertices.resize(0)
	UVs.resize(0)
	normals.resize(0)
	
	#previously generated terrain is removed
	get_tree().call_group_flags(SceneTree.GROUP_CALL_DEFERRED, &"terrains", &"queue_free")
	
	#find the min and max heights in the map for dynamic normalization
	var max_map_height: float = 0.0
	var min_visible_height: float = water_level
	for x in mapsize:
		for y in mapsize:
			if map[x][y] > max_map_height:
				max_map_height = map[x][y]
	
	var height_range: float = max_map_height - min_visible_height
	if height_range <= 0.0:
		height_range = 1.0
	
	if OS.is_debug_build() and debug_prints: print("[DEBUG] Terrain height range: %.2f to %.2f (visible: %.2f to %.2f, range=%.2f)" % [0.0, max_map_height, min_visible_height, max_map_height, height_range])
	
	for x in width-1:
		for y in height-1:
			create_quad(x,y)

	var st = SurfaceTool.new()
	
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var terrain_material = load(terrain_material_file)
	
	for v in vertices.size(): #assign color to vertices according to height
		var heightcolor
		if vertices[v].y <= min_visible_height:
			heightcolor = height_gradient.get_color(0)
		elif vertices[v].y > min_visible_height:
			# normalize height to 0-1 range using dynamic range above water
			var h: float = clampf((vertices[v].y - min_visible_height) / height_range, 0.0, 1.0)
			heightcolor = height_gradient.sample(h)
		else:
			heightcolor = snow
		st.set_color(heightcolor)
		
		st.set_normal(Vector3(0,1,0))
		st.set_uv(UVs[v])
		st.add_vertex(vertices[v])
	
	st.generate_normals()
	#create a new terrain MeshInstance and add it as a child
	var terrainmesh_new = MeshInstance3D.new()
	add_child(terrainmesh_new)
	terrainmesh_new.mesh = st.commit()
	terrainmesh_new.material_override = terrain_material
	terrainmesh_new.add_to_group("terrains") #this group is cleared before new terrain is generated
	terrainmesh_new.create_trimesh_collision()
	#uncomment the following line if you want to save the terrain as a scene
	#var _newterrain = ResourceSaver.save("res://newterrain.tres", terrainmesh_new.mesh, ResourceSaver.FLAG_COMPRESS)
	
	if OS.is_debug_build() and debug_prints: print("[DEBUG] Terrain mesh created with %d vertices, %d triangles" % [vertices.size(), vertices.size() / 3.0])


func create_quad(x,y):
	
	var vert1 # vertex positions (Vector2)
	var vert2
	var vert3
	
	var side1 # sides of each triangle (Vector3)
	var side2
	
	var normal # normal for each triangle (Vector3)
	
	# triangle 1
	vert1 = Vector3(x,map[x][y],-y)
	vert2 = Vector3(x,map[x][y+1],-y-1)
	vert3 = Vector3(x+1,map[x+1][y+1],-y-1)
	vertices.push_back(vert1)
	vertices.push_back(vert2)
	vertices.push_back(vert3)
	
	UVs.push_back(Vector2(vert1.x/10, -vert1.z/10))
	UVs.push_back(Vector2(vert2.x/10, -vert2.z/10))
	UVs.push_back(Vector2(vert3.x/10, -vert3.z/10))
	
	side1 = vert2-vert1
	side2 = vert2-vert3
	normal = side1.cross(side2)
	
	for i in 3:
		normals.push_back(normal)
	
	# triangle 2
	vert1 = Vector3(x,map[x][y],-y)
	vert2 = Vector3(x+1,map[x+1][y+1],-y-1)
	vert3 = Vector3(x+1,map[x+1][y],-y)
	vertices.push_back(vert1)
	vertices.push_back(vert2)
	vertices.push_back(vert3)
	
	UVs.push_back(Vector2(vert1.x/10, -vert1.z/10))
	UVs.push_back(Vector2(vert2.x/10, -vert2.z/10))
	UVs.push_back(Vector2(vert3.x/10, -vert3.z/10))
	
	side1 = vert2-vert1
	side2 = vert2-vert3
	normal = side1.cross(side2)
	
	for i in 3:
		normals.push_back(normal)

#endregion

#region Diamond-Square Algorithm

func diamond_square():
	map.clear()
	chunk = size
	roughness = float(size)/jitter
	
	for y in mapsize: #initialize and fill the array with zeroes
		map.append([])
		for x in mapsize:
			map[y].append(0)

#uncomment the following 4 lines if you want to create basic terrain. For islands you need to keep corners and edges at 0 (or whatever your waterlevel is)
#	map[0][0] = rng.randf_range(-roughness,roughness)
#	map[0][size] = rng.randf_range(-roughness,roughness)
#	map[size][0] = rng.randf_range(-roughness,roughness)
#	map[size][size] = rng.randf_range(-roughness,roughness)
		
	while chunk > 1:
		half = chunk >> 1
		square_step()
		diamond_step()
		chunk = chunk >> 1
		roughness /= jitter


func square_step():
	for y in range(0, size, chunk):
		for x in range(0, size, chunk):
			randval = rng.randf_range(-roughness * 0.5, roughness * 0.5)
			map[y+half][x+half]=(map[y][x]+map[y][x+chunk]+map[y+chunk][x]+map[y+chunk][x+chunk])/4.0 + randval


func diamond_step():
	for y in range(0, mapsize, half):
		for x in range((y+half)%chunk, mapsize, chunk):
			randval = rng.randf_range(-roughness * 0.5, roughness * 0.5)
			#edge cases are only relevant in the diamond step.
			#for island creation edge values are set to 0. Uncomment to create regular terrain.
			if x == 0:
				continue 
				#map[y][x] = float((map[y-half][x] + map[y][x+half] + map[y+half][x])/3 + randval)
			elif x == size:
				continue 
				#map[y][x] = float((map[y-half][x] + map[y][x-half] + map[y+half][x])/3 + randval)
			elif y == 0:
				continue 
				#map[y][x] = float((map[y+half][x] + map[y][x-half] + map[y][x+half])/3 + randval)
			elif y == size:
				continue 
				#map[y][x] = float((map[y-half][x] + map[y][x-half] + map[y][x+half])/3 + randval)
			else:
				map[y][x] = (map[y-half][x] + map[y][x-half] + map[y][x+half] + map[y+half][x])/4.0 + randval

#endregion
