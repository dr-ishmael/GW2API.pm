CREATE DATABASE  IF NOT EXISTS `gw2api` /*!40100 DEFAULT CHARACTER SET utf8 */;
USE `gw2api`;
-- MySQL dump 10.13  Distrib 5.6.17, for Win32 (x86)
--
-- Host: 127.0.0.1    Database: gw2api
-- ------------------------------------------------------
-- Server version	5.6.16

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `skin_log_tb`
--

DROP TABLE IF EXISTS `skin_log_tb`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `skin_log_tb` (
  `skin_id` mediumint(8) unsigned NOT NULL,
  `skin_name` varchar(128) NOT NULL,
  `skin_type` varchar(32) NOT NULL,
  `skin_subtype` varchar(32) DEFAULT NULL,
  `skin_description` varchar(1024) DEFAULT NULL,
  `flag_hideiflocked` tinyint(1) NOT NULL,
  `flag_nocost` tinyint(1) NOT NULL,
  `flag_showinwardrobe` tinyint(1) NOT NULL,
  `skin_file_id` mediumint(9) NOT NULL,
  `skin_file_signature` char(40) NOT NULL,
  `armor_race` varchar(32) DEFAULT NULL,
  `armor_class` varchar(32) DEFAULT NULL,
  `weapon_damage_type` varchar(32) DEFAULT NULL,
  `skin_warnings` varchar(1024) DEFAULT NULL,
  `skin_md5` char(32) NOT NULL,
  `first_seen_build_id` mediumint(8) DEFAULT NULL,
  `first_seen_dt` datetime DEFAULT CURRENT_TIMESTAMP,
  `last_seen_build_id` mediumint(8) DEFAULT NULL,
  `last_seen_dt` datetime DEFAULT CURRENT_TIMESTAMP,
  `last_updt_build_id` mediumint(8) DEFAULT NULL,
  `last_updt_dt` timestamp NULL DEFAULT CURRENT_TIMESTAMP,
  `change_build_id` mediumint(8) DEFAULT NULL,
  `change_dt` timestamp NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2014-10-11 17:47:27
