from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    input_topic = LaunchConfiguration("input_topic")
    output_topic = LaunchConfiguration("output_topic")

    return LaunchDescription(
        [
            DeclareLaunchArgument("input_topic", default_value="/Odometry"),
            DeclareLaunchArgument(
                "output_topic", default_value="/fmu/in/vehicle_visual_odometry"
            ),
            Node(
                package="px4_odometry_bridge",
                executable="px4_visual_odometry_bridge",
                name="px4_visual_odometry_bridge",
                parameters=[
                    {
                        "input_topic": input_topic,
                        "output_topic": output_topic,
                    }
                ],
                output="screen",
            ),
        ]
    )
