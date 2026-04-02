cmake_minimum_required(VERSION 3.8)
project(px4_odometry_bridge)

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

find_package(ament_cmake REQUIRED)
find_package(Eigen3 REQUIRED)
find_package(nav_msgs REQUIRED)
find_package(px4_msgs REQUIRED)
find_package(rclcpp REQUIRED)

add_executable(px4_visual_odometry_bridge src/px4_visual_odometry_bridge.cpp)
target_link_libraries(px4_visual_odometry_bridge Eigen3::Eigen)
ament_target_dependencies(px4_visual_odometry_bridge rclcpp nav_msgs px4_msgs)

install(TARGETS px4_visual_odometry_bridge
  DESTINATION lib/${PROJECT_NAME}
)

install(DIRECTORY launch
  DESTINATION share/${PROJECT_NAME}
)

ament_package()
