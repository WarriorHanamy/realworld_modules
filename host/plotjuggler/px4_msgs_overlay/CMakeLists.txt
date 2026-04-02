cmake_minimum_required(VERSION 3.5)

project(px4_msgs)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
	add_compile_options(-Wall -Wextra)
endif()

find_package(ament_cmake REQUIRED)
find_package(builtin_interfaces REQUIRED)
find_package(rosidl_default_generators REQUIRED)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/msg")
	set(MSGS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/msg")
else()
	set(MSGS_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
endif()
file(GLOB PX4_MSGS RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" "${MSGS_DIR}/*.msg")
file(GLOB PX4_MSGS_VERSIONED RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" "${MSGS_DIR}/versioned/*.msg")
list(APPEND PX4_MSGS ${PX4_MSGS_VERSIONED})

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/srv")
	set(SRVS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/srv")
	file(GLOB PX4_SRVS RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" "${SRVS_DIR}/*.srv")
endif()

rosidl_generate_interfaces(${PROJECT_NAME}
	${PX4_MSGS}
	${PX4_SRVS}
	DEPENDENCIES builtin_interfaces
)

ament_export_dependencies(rosidl_default_runtime)

ament_package()
